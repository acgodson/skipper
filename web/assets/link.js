/* The browser leg of protocol/API.md §1.1: take the nonce and the device key the app put in
   the URL, let Cognito's hosted sign-in do the authentication, mint the one-time code with
   POST /v1/auth/link, and hand both back to the app over skipperdesk://link.

   Three things in here are load-bearing and look arbitrary without the contract:

   - The nonce is echoed byte for byte and is never re-derived, re-encoded or regenerated.
     The app compares it in constant time and abandons the sign-in on any difference
     (§1.1 rule 1), which is the whole reason this page is allowed to be untrusted.
   - The bearer sent to /v1/auth/link is the ID token, not the access token. The API's
     user-session check needs an `email` claim, and Cognito puts that in the ID token only.
   - Nothing about the attempt is trusted from the callback URL. The nonce, the device key
     and the PKCE verifier are read back out of sessionStorage, keyed by a random `state`
     that Cognito round-trips, so a callback this page did not start cannot finish. */

(function () {
	"use strict";

	var CONFIG = window.SKIPPER_CONFIG || {};
	var STORE_KEY = "skipperdesk.signin";
	var CALLBACK_PATH = "/link";
	var HANDOFF_SCHEME = "skipperdesk://link";
	var SCOPES = "openid email profile";

	/* The app abandons a sign-in 15 minutes after it opened the browser (§1.1 rule 1, and
	   AccountLinker.linkAttemptLifetime). Past this point the handoff would be dropped
	   with nothing on screen, so the page says so instead of burning a one-time code.

	   The margin is a minute, and it is one-sided on purpose: this page starts counting
	   when it loads, which is always after the app started counting, so the page's clock
	   reading is behind the app's by however long the browser took to launch. A minute
	   covers that and matches the skew the API tolerates elsewhere (§0, Clock). */
	var ATTEMPT_BUDGET_MS = 14 * 60 * 1000;

	var NONCE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
	var PUBKEY_PATTERN = /^[A-Za-z0-9+/]{100,400}={0,2}$/;
	var PLATFORM_PATTERN = /^[a-z][a-z0-9]{1,15}$/;
	var LABEL_MAX = 64;

	var SAY = {
		startFromApp: [
			"neutral",
			"Start from SkipperDesk",
			"Open SkipperDesk on the Mac you want to sign in and choose Sign in. This page is " +
			"the second half of that."
		],
		startAgain: [
			"critical",
			"Sign-in could not be completed",
			"Open SkipperDesk and choose Sign in again."
		],
		notOurs: [
			"critical",
			"Sign-in could not be completed",
			"Open SkipperDesk and choose Sign in again. This page cannot finish a sign-in it " +
			"did not start."
		],
		cancelled: [
			"attention",
			"Sign-in was cancelled",
			"Open SkipperDesk and choose Sign in again when you are ready."
		],
		tooSlow: [
			"attention",
			"That took longer than SkipperDesk waits",
			"Open SkipperDesk and choose Sign in again. It should take only a moment now that " +
			"you are signed in here."
		],
		browser: [
			"critical",
			"This browser cannot sign you in",
			"Open the page again in Safari, Chrome or Edge, with an address that starts with " +
			"https, and allow it to store site data."
		],
		unavailable: [
			"attention",
			"SkipperDesk could not sign you in just now",
			"Try again in a few minutes from SkipperDesk."
		],
		busy: [
			"attention",
			"Too many sign-in attempts",
			"Wait a few minutes, then open SkipperDesk and choose Sign in again."
		],
		update: [
			"attention",
			"SkipperDesk needs updating",
			"Update SkipperDesk on that Mac, then sign in again."
		],
		elsewhere: [
			"critical",
			"That Mac is signed in to another account",
			"The Mac you are signing in already belongs to a different SkipperDesk account. " +
			"Open SkipperDesk on that Mac, sign out there, then sign in again here. A Mac can " +
			"belong to one account at a time."
		],
		handedBack: [
			"positive",
			"You are signed in",
			"SkipperDesk is taking it from here. If it did not come forward, use the button below."
		]
	};

	function el(id) {
		return document.getElementById(id);
	}

	function say(message) {
		el("working").classList.add("hidden");
		var banner = el("message");
		banner.className = "banner " + message[0];
		el("message-title").textContent = message[1];
		el("message-body").textContent = message[2];
		document.title = message[1] + " · SkipperDesk";
	}

	function working(text) {
		el("working-text").textContent = text;
	}

	function base64url(bytes) {
		var out = "";
		for (var i = 0; i < bytes.length; i += 1) {
			out += String.fromCharCode(bytes[i]);
		}
		return btoa(out).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
	}

	function randomBase64url(length) {
		var bytes = new Uint8Array(length);
		crypto.getRandomValues(bytes);
		return base64url(bytes);
	}

	function challengeFor(verifier) {
		var ascii = new Uint8Array(verifier.length);
		for (var i = 0; i < verifier.length; i += 1) {
			ascii[i] = verifier.charCodeAt(i);
		}
		return crypto.subtle.digest("SHA-256", ascii).then(function (digest) {
			return base64url(new Uint8Array(digest));
		});
	}

	function idempotencyKey() {
		if (typeof crypto.randomUUID === "function") {
			return crypto.randomUUID();
		}
		return randomBase64url(24);
	}

	function remember(attempt) {
		sessionStorage.setItem(STORE_KEY, JSON.stringify(attempt));
	}

	function recall() {
		var raw = sessionStorage.getItem(STORE_KEY);
		sessionStorage.removeItem(STORE_KEY);
		return raw ? JSON.parse(raw) : null;
	}

	function forget() {
		try {
			sessionStorage.removeItem(STORE_KEY);
		} catch (ignored) {
			return;
		}
	}

	function scrub() {
		try {
			history.replaceState({}, "", CALLBACK_PATH);
		} catch (ignored) {
			return;
		}
	}

	function usable() {
		if (!CONFIG.cognitoDomain || !CONFIG.cognitoClientId || !CONFIG.apiBase) {
			return false;
		}
		if (!window.crypto || !crypto.getRandomValues || !crypto.subtle) {
			return false;
		}
		try {
			sessionStorage.setItem(STORE_KEY + ".probe", "1");
			sessionStorage.removeItem(STORE_KEY + ".probe");
		} catch (blocked) {
			return false;
		}
		return true;
	}

	function redirectURI() {
		return location.origin + CALLBACK_PATH;
	}

	function begin(params) {
		var nonce = params.get("nonce") || "";
		var pubkey = params.get("device") || "";
		var platform = params.get("platform") || "macos";
		var label = (params.get("label") || "").trim().slice(0, LABEL_MAX);

		if (!NONCE_PATTERN.test(nonce) || !PUBKEY_PATTERN.test(pubkey) ||
			!PLATFORM_PATTERN.test(platform)) {
			scrub();
			say(SAY.startAgain);
			return;
		}

		var state = randomBase64url(32);
		var verifier = randomBase64url(32);

		challengeFor(verifier).then(function (challenge) {
			remember({
				state: state,
				verifier: verifier,
				nonce: nonce,
				pubkey: pubkey,
				platform: platform,
				label: label,
				startedAt: Date.now()
			});
			var query = new URLSearchParams({
				response_type: "code",
				client_id: CONFIG.cognitoClientId,
				redirect_uri: redirectURI(),
				scope: SCOPES,
				state: state,
				code_challenge: challenge,
				code_challenge_method: "S256"
			});
			working("Taking you to sign-in…");
			location.replace(CONFIG.cognitoDomain + "/oauth2/authorize?" + query.toString());
		}).catch(function () {
			say(SAY.browser);
		});
	}

	function exchange(attempt, code) {
		var body = new URLSearchParams({
			grant_type: "authorization_code",
			client_id: CONFIG.cognitoClientId,
			code: code,
			redirect_uri: redirectURI(),
			code_verifier: attempt.verifier
		});
		return fetch(CONFIG.cognitoDomain + "/oauth2/token", {
			method: "POST",
			headers: { "Content-Type": "application/x-www-form-urlencoded" },
			body: body.toString(),
			cache: "no-store",
			credentials: "omit"
		}).then(function (response) {
			if (!response.ok) {
				throw new Error("token");
			}
			return response.json();
		}).then(function (tokens) {
			if (!tokens || typeof tokens.id_token !== "string" || !tokens.id_token) {
				throw new Error("token");
			}
			return tokens.id_token;
		});
	}

	function mintCode(attempt, bearer) {
		var payload = {
			nonce: attempt.nonce,
			pubkey: attempt.pubkey,
			platform: attempt.platform
		};
		if (attempt.label) {
			payload.label = attempt.label;
		}
		return fetch(CONFIG.apiBase + "/v1/auth/link", {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				"Authorization": "Bearer " + bearer,
				"Idempotency-Key": idempotencyKey()
			},
			body: JSON.stringify(payload),
			cache: "no-store",
			credentials: "omit"
		});
	}

	function failureFor(status, reason) {
		if (status === 409 && reason === "linked_elsewhere") {
			return SAY.elsewhere;
		}
		if (status === 429) {
			return SAY.busy;
		}
		if (status === 426) {
			return SAY.update;
		}
		if (status >= 500) {
			return SAY.unavailable;
		}
		return SAY.startAgain;
	}

	function handOff(code, nonce) {
		var target = HANDOFF_SCHEME +
			"?code=" + encodeURIComponent(code) +
			"&nonce=" + encodeURIComponent(nonce);
		var button = el("handoff");
		button.setAttribute("href", target);
		el("actions").classList.remove("hidden");
		say(SAY.handedBack);
		setTimeout(function () {
			location.replace(target);
		}, 150);
	}

	function finish(params) {
		var error = params.get("error");
		var code = params.get("code") || "";
		var state = params.get("state") || "";
		var attempt = null;

		try {
			attempt = recall();
		} catch (unreadable) {
			attempt = null;
		}
		scrub();

		if (error) {
			say(error === "access_denied" ? SAY.cancelled : SAY.startAgain);
			return;
		}
		if (!attempt || !attempt.state || !state || attempt.state !== state || !code) {
			say(SAY.notOurs);
			return;
		}
		if (Date.now() - attempt.startedAt > ATTEMPT_BUDGET_MS) {
			say(SAY.tooSlow);
			return;
		}

		working("Finishing your sign-in…");
		exchange(attempt, code).then(function (bearer) {
			return mintCode(attempt, bearer);
		}).then(function (response) {
			if (response.status === 201) {
				return response.json().then(function (answer) {
					if (!answer || typeof answer.code !== "string" || !answer.code) {
						throw new Error("answer");
					}
					handOff(answer.code, attempt.nonce);
				});
			}
			return response.json().catch(function () {
				return {};
			}).then(function (envelope) {
				var detail = (envelope && envelope.error) || {};
				say(failureFor(response.status, detail.reason));
			});
		}).catch(function () {
			say(SAY.unavailable);
		});
	}

	function start() {
		var params = new URLSearchParams(location.search);

		if (!usable()) {
			scrub();
			var configured = CONFIG.cognitoDomain && CONFIG.cognitoClientId && CONFIG.apiBase;
			say(configured ? SAY.browser : SAY.unavailable);
			return;
		}
		if (params.has("code") || params.has("error")) {
			finish(params);
			return;
		}
		if (params.has("nonce") || params.has("device")) {
			forget();
			begin(params);
			return;
		}
		forget();
		scrub();
		say(SAY.startFromApp);
	}

	start();
}());
