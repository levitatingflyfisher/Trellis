/// Law 4: the proxied-body ceiling. 32 MiB covers the largest sane
/// document/EPUB this daemon would ever be asked to fetch on the app's
/// behalf — never media. Podcast/episode AUDIO never routes through
/// Skein: browser `<audio>`/`<video>` elements play cross-origin without
/// CORS at all (no fetch, no XHR involved), so direct playback already
/// works — proxying it through here would only add a hop and spend this
/// cap on bytes that never needed a proxy.
const int skeinMaxFetchBytes = 32 * 1024 * 1024;
