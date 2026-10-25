# Blob downloads: manual device checks (maintainer)

Not part of the public wiki. Run in the Showcase app on a real `WKWebView`; the automated tests cannot start a WebKit download.

| # | Check | iPad (OS / date) | Mac (OS / date) |
|---|---|---|---|
| a | `URL.createObjectURL(blob)` + a detached `<a download>` + `click()` + immediate `URL.revokeObjectURL`: the file is saved with its name | | |
| b | A link to a URL answered with `Content-Disposition: attachment` downloads | | |
| c | `window.open(url)` of an attachment downloads and the page stays where it is | | |
| d | A Live Pages `.download` event saves the file | | |
| e | An upload over the limit (`413`) shows a readable error, not a blank page or a reset | | |
