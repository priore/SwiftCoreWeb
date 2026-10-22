// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// The browser-side half of `useBlobDownloads`: a classic, same-origin script
/// (no `eval`, no `new Function`, fine under `default-src 'self'`) that makes
/// `URL.createObjectURL(blob)` + `<a download>` + `click()` downloads work in
/// web views that ignore `blob:` downloads (WKWebView). It knows nothing about
/// WebKit: it uploads the Blob to `POST /_framework/blob` and navigates a hidden
/// anchor to the one-time URL the server returns.
///
/// Served at `/_framework/blob-download.js`; also a constant so a host app can
/// embed it (e.g. as a `WKUserScript`) without an HTTP round trip.
///
/// ponytail: a revoked Blob is kept for a fixed 30 s grace (timer-only), not until the upload finishes.
public enum BlobDownloadShim {
    public static let source = #"""
    (function () {
      if (window.__scwBlobShim) return;
      window.__scwBlobShim = true;

      var REVOKE_GRACE_MS = 30000;
      var blobs = new Map();          // object URL -> Blob
      var passthrough = new WeakSet(); // anchors we gave up on: let the browser handle them

      var createObjectURL = URL.createObjectURL;
      var revokeObjectURL = URL.revokeObjectURL;
      URL.createObjectURL = function (object) {
        var url = createObjectURL.apply(URL, arguments);
        if (object instanceof Blob) blobs.set(url, object);
        return url;
      };
      // Pages revoke right after click(): keep the Blob a while, never fetch(blob:).
      URL.revokeObjectURL = function (url) {
        setTimeout(function () { blobs.delete(url); }, REVOKE_GRACE_MS);
        return revokeObjectURL.apply(URL, arguments);
      };

      function isBlobDownload(a) {
        return !!a && a.tagName === 'A' && a.hasAttribute('download') && !passthrough.has(a) &&
          typeof a.href === 'string' && a.href.indexOf('blob:') === 0;
      }

      var nativeClick = HTMLAnchorElement.prototype.click;
      var nativeDispatch = HTMLAnchorElement.prototype.dispatchEvent;

      function navigate(url) {
        var link = document.createElement('a');
        link.href = url;
        link.download = '';
        link.style.display = 'none';
        document.body.appendChild(link);
        nativeClick.call(link);
        setTimeout(function () { link.remove(); }, 0);
      }

      function intercept(a) {
        var url = a.href;
        var name = a.getAttribute('download') || 'download';
        var blob = blobs.get(url);
        var source = blob ? Promise.resolve(blob) : fetch(url).then(function (r) { return r.blob(); });
        source.then(function (b) {
          return fetch('/_framework/blob', {
            method: 'POST',
            credentials: 'same-origin',
            headers: {
              'X-SCW-Blob': '1',
              'X-SCW-Filename': encodeURIComponent(name),
              'Content-Type': b.type || 'application/octet-stream'
            },
            body: b
          });
        }).then(function (r) {
          if (!r.ok) throw new Error('blob download failed: ' + r.status);
          return r.json();
        }).then(function (json) {
          navigate(json.url);
        }).catch(function (error) {
          document.dispatchEvent(new CustomEvent('blob-download:error', { detail: error }));
          passthrough.add(a);
          try { nativeClick.call(a); } finally { passthrough.delete(a); }
        });
      }

      // Detached anchors never reach document listeners: patch the entry points.
      HTMLAnchorElement.prototype.click = function () {
        if (isBlobDownload(this)) { intercept(this); return; }
        return nativeClick.apply(this, arguments);
      };
      HTMLAnchorElement.prototype.dispatchEvent = function (event) {
        if (event && event.type === 'click' && isBlobDownload(this)) { intercept(this); return true; }
        return nativeDispatch.apply(this, arguments);
      };
      // Real user clicks on attached anchors.
      document.addEventListener('click', function (event) {
        var a = event.target && event.target.closest ? event.target.closest('a') : null;
        if (isBlobDownload(a)) { event.preventDefault(); intercept(a); }
      }, true);
    })();
    """#
}
