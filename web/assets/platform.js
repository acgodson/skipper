/* Promotes the download that matches the visitor's computer. With no script, or an unknown
   system, both downloads stay shown at equal weight; nothing is ever hidden by a guess. */

(function () {
	"use strict";

	function detect() {
		var data = navigator.userAgentData;
		var platform = data && data.platform ? data.platform : "";
		var agent = navigator.userAgent || "";
		var text = platform || agent;
		if (/windows/i.test(text)) return "windows";
		if (/mobile|android|iphone|ipad|cros|linux/i.test(agent)) return "other";
		if (/mac/i.test(text) && !(navigator.maxTouchPoints > 1)) return "mac";
		return "other";
	}

	var os = detect();
	if (os === "other") return;

	var match = document.getElementById(os === "windows" ? "dl-win" : "dl-mac");
	if (!match) return;

	match.classList.add("is-match");
	document.documentElement.setAttribute("data-os", os);
})();
