/* Two request fixes CloudFront has no setting for.

   www goes to the apex, because only the apex is a registered Cognito callback URL and the
   sign-in page builds its redirect_uri from the origin it is loaded on.

   A path with no filename gets /index.html, because an S3 origin has no directory index:
   without this, /link is a missing key rather than web/link/index.html. default_root_object
   covers only "/". Written in ES5 on purpose — that is the floor both CloudFront Functions
   runtimes guarantee. */

function handler(event) {
	var request = event.request;
	var host = request.headers.host ? request.headers.host.value : "";

	if (host.indexOf("www.") === 0) {
		var query = [];
		for (var name in request.querystring) {
			query.push(encodeURIComponent(name) + "=" +
				encodeURIComponent(request.querystring[name].value));
		}
		var suffix = query.length ? "?" + query.join("&") : "";
		return {
			statusCode: 301,
			statusDescription: "Moved Permanently",
			headers: {
				location: { value: "https://" + host.substring(4) + request.uri + suffix },
				"cache-control": { value: "max-age=3600" }
			}
		};
	}

	var uri = request.uri;
	var last = uri.substring(uri.lastIndexOf("/") + 1);

	if (last === "") {
		request.uri = uri + "index.html";
	} else if (last.indexOf(".") === -1) {
		request.uri = uri + "/index.html";
	}

	return request;
}
