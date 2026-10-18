// In front of the static files: http becomes https, and browsers are told to stay on https.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol === "http:") {
      url.protocol = "https:";
      return Response.redirect(url.toString(), 301);
    }
    const response = await env.ASSETS.fetch(request);
    const secured = new Response(response.body, response);
    secured.headers.set("Strict-Transport-Security", "max-age=31536000");
    return secured;
  },
};
