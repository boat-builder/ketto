import { SELF, env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "../Ketto/Resources/CloudflareBackend/worker.js";

// Must match the binding in vitest.config.mjs.
const TOKEN = "test-token-0123456789abcdef";
const ORIGIN = "https://share.example.test";
const MIB = 1024 * 1024;
const DAY_MS = 24 * 60 * 60 * 1000;

function api(path, init = {}) {
  const headers = new Headers(init.headers || {});
  headers.set("Authorization", `Bearer ${TOKEN}`);
  return SELF.fetch(`${ORIGIN}${path}`, { ...init, headers });
}

function bytes(length, seed) {
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) out[i] = (i * 31 + seed) & 0xff;
  return out;
}

async function clearBucket() {
  const listed = await env.VIDEOS.list();
  if (listed.objects.length > 0) await env.VIDEOS.delete(listed.objects.map((object) => object.key));
}

/** Runs the whole create / parts / complete flow the app performs and returns what it gets back. */
async function share(title, parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const created = await api("/api/uploads", {
    method: "POST",
    body: JSON.stringify({ title, filename: `${title}.mp4`, size: total, contentType: "video/mp4" }),
  });
  expect(created.status).toBe(201);
  const { id, uploadId, partSize } = await created.json();
  const etags = [];
  for (const [index, part] of parts.entries()) {
    const response = await api(`/api/uploads/${id}/${encodeURIComponent(uploadId)}/${index + 1}`, { method: "PUT", body: part });
    expect(response.status).toBe(200);
    etags.push(await response.json());
  }
  const completed = await api(`/api/uploads/${id}/${encodeURIComponent(uploadId)}/complete`, {
    method: "POST",
    body: JSON.stringify({ parts: etags }),
  });
  expect(completed.status).toBe(201);
  return { id, uploadId, partSize, total, video: await completed.json() };
}

describe("ketto-share worker", () => {
  beforeEach(clearBucket);

  it("reports the service and api version without a token", async () => {
    const response = await SELF.fetch(`${ORIGIN}/`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ service: "ketto-share", api: 1 });
  });

  it("rejects api calls without the right token", async () => {
    expect((await SELF.fetch(`${ORIGIN}/api/status`)).status).toBe(401);
    expect((await SELF.fetch(`${ORIGIN}/api/status`, { headers: { Authorization: "Bearer nope" } })).status).toBe(401);
    expect((await SELF.fetch(`${ORIGIN}/api/videos`, { headers: { Authorization: `Bearer ${TOKEN}x` } })).status).toBe(401);
    expect((await SELF.fetch(`${ORIGIN}/api/videos`, { headers: { Authorization: TOKEN } })).status).toBe(401);
    const ok = await api("/api/status");
    expect(ok.status).toBe(200);
    expect(await ok.json()).toEqual({ ok: true, api: 1, bucket: "ketto-videos-dev" });
  });

  it("fails closed while the token secret is missing", async () => {
    const request = new Request(`${ORIGIN}/api/status`, { headers: { Authorization: `Bearer ${TOKEN}` } });
    const context = createExecutionContext();
    const response = await worker.fetch(request, { VIDEOS: env.VIDEOS }, context);
    await waitOnExecutionContext(context);
    expect(response.status).toBe(503);
  });

  it("uploads in parts, serves the video with ranges, lists it and deletes it", async () => {
    const parts = [bytes(5 * MIB, 1), bytes(100, 2)];
    const { id, partSize, total, video } = await share("Demo recording", parts);
    expect(partSize).toBe(32 * MIB);
    expect(video).toMatchObject({ id, title: "Demo recording", size: total, url: `${ORIGIN}/v/${id}` });
    expect(new Date(video.expires) - new Date(video.uploaded)).toBe(3 * DAY_MS);

    const file = `${ORIGIN}/f/${id}`;
    const full = await SELF.fetch(file);
    expect(full.status).toBe(200);
    expect(full.headers.get("Content-Type")).toBe("video/mp4");
    expect(full.headers.get("Accept-Ranges")).toBe("bytes");
    expect(full.headers.get("Content-Length")).toBe(String(total));
    expect(full.headers.get("Content-Disposition")).toContain('inline; filename="Demo recording.mp4"');
    const body = new Uint8Array(await full.arrayBuffer());
    expect(body.length).toBe(total);
    expect(body.slice(0, 8)).toEqual(parts[0].slice(0, 8));
    expect(body.slice(total - 4)).toEqual(parts[1].slice(96));

    const ranged = await SELF.fetch(file, { headers: { Range: "bytes=10-19" } });
    expect(ranged.status).toBe(206);
    expect(ranged.headers.get("Content-Range")).toBe(`bytes 10-19/${total}`);
    expect(ranged.headers.get("Content-Length")).toBe("10");
    expect(new Uint8Array(await ranged.arrayBuffer())).toEqual(parts[0].slice(10, 20));

    const suffix = await SELF.fetch(file, { headers: { Range: "bytes=-5" } });
    expect(suffix.status).toBe(206);
    expect(suffix.headers.get("Content-Range")).toBe(`bytes ${total - 5}-${total - 1}/${total}`);
    expect(new Uint8Array(await suffix.arrayBuffer())).toEqual(parts[1].slice(95));

    const head = await SELF.fetch(file, { method: "HEAD" });
    expect(head.status).toBe(200);
    expect(head.headers.get("Content-Length")).toBe(String(total));
    expect(head.headers.get("Content-Type")).toBe("video/mp4");

    const notModified = await SELF.fetch(file, { headers: { "If-None-Match": full.headers.get("ETag") } });
    expect(notModified.status).toBe(304);

    const listed = await api("/api/videos");
    expect(listed.status).toBe(200);
    const { videos } = await listed.json();
    expect(videos).toHaveLength(1);
    expect(videos[0]).toEqual(video);

    expect((await api(`/api/videos/${id}`, { method: "DELETE" })).status).toBe(204);
    expect((await api(`/api/videos/${id}`, { method: "DELETE" })).status).toBe(404);
    expect((await SELF.fetch(file)).status).toBe(404);
    const gone = await SELF.fetch(video.url);
    expect(gone.status).toBe(404);
    expect(gone.headers.get("Content-Type")).toContain("text/html");
    expect((await (await api("/api/videos")).json()).videos).toEqual([]);
  });

  it("serves one viewer page per link, built from the object's metadata", async () => {
    const { id, video } = await share("Demo recording", [bytes(64, 6)]);

    const page = await SELF.fetch(video.url);
    expect(page.status).toBe(200);
    expect(page.headers.get("Content-Type")).toContain("text/html");
    // Rendered live so a deleted video stops playing; the bytes behind /f are what gets cached.
    expect(page.headers.get("Cache-Control")).toBe("no-store");
    const html = await page.text();

    // The page is the player; the video streams from /f, which is why the link survives a redesign.
    expect(html).toContain(`src="/f/${id}"`);
    expect(html).toContain(`href="/f/${id}?download=1"`);
    expect(html).toContain(`data-expires="${video.expires}"`);
    expect(html).toContain("<title>Demo recording \u00b7 Ketto</title>");
    expect(html).toMatch(/SPEEDS = \[0\.5, 1, 1\.25, 1\.5, 1\.75, 2\]/);
    expect(html).not.toContain("videos/");

    // Style and script carry the nonce the CSP names, so neither needs 'unsafe-inline'.
    const csp = page.headers.get("Content-Security-Policy");
    const nonce = /'nonce-([a-f0-9]{32})'/.exec(csp)[1];
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain(`style-src 'nonce-${nonce}'`);
    expect(csp).toContain(`script-src 'nonce-${nonce}'`);
    expect(html).toContain(`<style nonce="${nonce}">`);
    expect(html).toContain(`<script nonce="${nonce}">`);

    const head = await SELF.fetch(video.url, { method: "HEAD" });
    expect(head.status).toBe(200);
    expect(await head.text()).toBe("");

    const missing = await SELF.fetch(`${ORIGIN}/v/${"a".repeat(26)}`);
    expect(missing.status).toBe(404);
    expect(missing.headers.get("Content-Type")).toContain("text/html");
  });

  it("escapes the title everywhere it puts it in the page", async () => {
    const { video } = await share('Trouble <script>alert(1)</script> & "quotes"', [bytes(16, 7)]);
    const html = await (await SELF.fetch(video.url)).text();
    expect(html).not.toContain("<script>alert(1)");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(html).toContain("&amp;");
    expect(html).toContain("&quot;quotes&quot;");
    // Including the copy that rides in the link-preview metadata.
    expect(html).toMatch(/<meta property="og:title" content="Trouble &lt;script&gt;[^"]*">/);
  });

  it("offers the file inline to the player and as a download on request", async () => {
    const { id } = await share("Demo recording", [bytes(32, 8)]);
    const inline = await SELF.fetch(`${ORIGIN}/f/${id}`);
    expect(inline.headers.get("Content-Disposition")).toContain('inline; filename="Demo recording.mp4"');
    const download = await SELF.fetch(`${ORIGIN}/f/${id}?download=1`);
    expect(download.status).toBe(200);
    expect(download.headers.get("Content-Disposition")).toContain('attachment; filename="Demo recording.mp4"');
    expect((await download.arrayBuffer()).byteLength).toBe(32);
  });

  it("answers 416 past the end, clamps an overshooting range and ignores a malformed one", async () => {
    const { video, total } = await share("Short", [bytes(50, 3)]);
    const file = `${ORIGIN}/f/${video.id}`;
    const beyond = await SELF.fetch(file, { headers: { Range: `bytes=${total + 10}-` } });
    expect(beyond.status).toBe(416);
    expect(beyond.headers.get("Content-Range")).toBe(`bytes */${total}`);
    const overshoot = await SELF.fetch(file, { headers: { Range: `bytes=45-${total + 20}` } });
    expect(overshoot.status).toBe(206);
    expect(overshoot.headers.get("Content-Range")).toBe(`bytes 45-${total - 1}/${total}`);
    expect((await overshoot.arrayBuffer()).byteLength).toBe(total - 45);
    const malformed = await SELF.fetch(file, { headers: { Range: "bytes=abc" } });
    expect(malformed.status).toBe(200);
    expect(malformed.headers.get("Content-Length")).toBe(String(total));
  });

  it("aborts an upload so nothing is left behind", async () => {
    const created = await api("/api/uploads", { method: "POST", body: JSON.stringify({ title: "Draft", size: 10 }) });
    const { id, uploadId } = await created.json();
    expect((await api(`/api/uploads/${id}/${encodeURIComponent(uploadId)}`, { method: "DELETE" })).status).toBe(204);
    expect((await SELF.fetch(`${ORIGIN}/v/${id}`)).status).toBe(404);
    expect((await (await api("/api/videos")).json()).videos).toEqual([]);
  });

  it("sanitises titles and falls back for missing ones", async () => {
    const { video } = await share("  Weird  title\n\twith  spaces  ", [bytes(20, 4)]);
    expect(video.title).toBe("Weird title with spaces");
    const created = await api("/api/uploads", { method: "POST", body: JSON.stringify({ size: 3 }) });
    const { id, uploadId } = await created.json();
    const part = await api(`/api/uploads/${id}/${encodeURIComponent(uploadId)}/1`, { method: "PUT", body: bytes(3, 5) });
    const completed = await api(`/api/uploads/${id}/${encodeURIComponent(uploadId)}/complete`, {
      method: "POST",
      body: JSON.stringify({ parts: [await part.json()] }),
    });
    expect((await completed.json()).title).toBe("Untitled");
  });

  it("validates requests", async () => {
    expect((await api("/api/uploads", { method: "POST", body: "not json" })).status).toBe(400);
    expect((await api("/api/uploads", { method: "POST", body: JSON.stringify({ title: "x", size: 0 }) })).status).toBe(400);
    expect((await api("/api/uploads", { method: "POST", body: JSON.stringify({ title: "x", size: "lots" }) })).status).toBe(400);
    const created = await api("/api/uploads", { method: "POST", body: JSON.stringify({ title: "x", size: 10 }) });
    const { id, uploadId } = await created.json();
    const upload = `/api/uploads/${id}/${encodeURIComponent(uploadId)}`;
    expect((await api(`${upload}/0`, { method: "PUT", body: bytes(10, 0) })).status).toBe(400);
    expect((await api(`${upload}/complete`, { method: "POST", body: JSON.stringify({ parts: [] }) })).status).toBe(400);
    expect((await api(`${upload}/complete`, { method: "POST", body: JSON.stringify({ parts: [{ partNumber: 1 }] }) })).status).toBe(400);
    expect((await SELF.fetch(`${ORIGIN}/v/not-a-valid-id`)).status).toBe(404);
    expect((await SELF.fetch(`${ORIGIN}/v/${id}`)).status).toBe(404);
    expect((await api("/api/nope")).status).toBe(404);
    expect((await api("/api/videos", { method: "POST" })).status).toBe(404);
  });
});
