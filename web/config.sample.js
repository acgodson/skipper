/* The shape of /config.js. Terraform owns the real file: infra/web/terraform/site.tf writes
   it into the bucket from the backend stack's outputs, so no identifier is committed here.
   scripts/serve-web.sh writes a local copy of this for offline work. */

window.SKIPPER_CONFIG = {
	cognitoDomain: "https://<prefix>.auth.<region>.amazoncognito.com",
	cognitoClientId: "<cognito app client id>",
	apiBase: "https://api.skipperdesk.app"
};
