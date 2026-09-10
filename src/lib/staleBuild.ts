/**
 * staleBuild.ts — telling somebody a deploy happened, in words they can act on.
 *
 * THE FAILURE
 * ═══════════
 *   Vite splits the app into content-hashed chunks: TimesheetPDF-yMUdwYJv.js,
 *   TimesheetDetail-<hash>.js, and six more. A tab that was opened before a
 *   deploy is still running the old index.html, which names the OLD hashes --
 *   and those files no longer exist on the server. Nothing breaks while the
 *   page sits there, because a lazy chunk is only fetched when somebody
 *   reaches the feature. Then:
 *
 *       Export failed — Failed to fetch dynamically imported module:
 *       https://dev.prowessapp.net/assets/TimesheetPDF-yMUdwYJv.js
 *
 *   Which reads as "the PDF is broken". It is not: the PDF is fine, the tab is
 *   old. There is nothing the user can do about the sentence they were shown,
 *   and exactly one thing they can do about the situation -- reload -- and the
 *   message does not mention it.
 *
 *   Eight lazy chunks carry this fault, five of them the report tabs. Whoever
 *   has Prowess open during a deploy meets it on whichever they click first.
 *
 * WHY IT DOES NOT RELOAD BY ITSELF
 * ════════════════════════════════
 *   Because a reload throws away whatever is on screen -- a half-filled Create
 *   Attendance modal, an entry typed and not yet saved. The person is mid-task
 *   by definition: they just clicked something. Losing their work to fix a
 *   problem they did not cause and cannot see is a worse trade than one more
 *   click, so this asks.
 *
 * WHY IT DOES NOT CALL preventDefault()
 * ═════════════════════════════════════
 *   Vite's preload helper dispatches `vite:preloadError` and then rethrows --
 *   `if (!e.defaultPrevented) throw err`. Calling preventDefault stops the
 *   throw, which sounds helpful and is not: the awaiting code then resolves
 *   with `undefined` and dies one line later on
 *
 *       const [{ pdf }, { TimesheetPDF }] = await Promise.all([...])
 *
 *   with "Cannot destructure property 'pdf' of 'undefined'" -- a message that
 *   has lost every trace of what actually went wrong. So the error is left to
 *   propagate exactly as it does today. This listens; it does not intervene.
 */

/** What the banner and the toasts say. One sentence, one instruction. */
export const STALE_BUILD_MESSAGE =
  'A new version of Prowess has been released. Reload the page to continue.';

let detected = false;

/**
 * Is this error a chunk that no longer exists?
 *
 * Two independent signals, because neither is sufficient alone:
 *
 *   1. `detected` -- vite:preloadError fired. Authoritative when it fires, but
 *      it only covers imports that went through Vite's preload helper.
 *   2. The message. Every browser words this differently and none of them is
 *      a documented contract, so the list is a best effort over the three
 *      engines rather than a rule:
 *        Chrome / Edge : "Failed to fetch dynamically imported module: <url>"
 *        Firefox       : "error loading dynamically imported module: <url>"
 *        Safari        : "Importing a module script failed."
 *
 * A false positive costs an unnecessary "reload" suggestion on some other
 * network failure, which is nearly always sound advice anyway. A false
 * negative costs the raw message -- today's behaviour. Both are survivable,
 * and that is the reason this is a hint and not a redirect.
 */
export function isStaleBuildError(err: unknown): boolean {
  if (detected) return true;
  const msg = err instanceof Error ? err.message : String(err ?? '');
  return /failed to fetch dynamically imported module/i.test(msg)
      || /error loading dynamically imported module/i.test(msg)
      || /importing a module script failed/i.test(msg)
      || /dynamically imported module/i.test(msg);
}

/**
 * The banner is built with DOM calls, not React, and that is deliberate.
 *
 * The event that brings us here means a JavaScript chunk failed to load. A
 * React component is the one thing that might not be able to render at that
 * moment -- and if it cannot, the person is left with the raw error and no
 * banner at all. document.createElement always works.
 */
function showBanner() {
  const ID = 'prowess-stale-build';
  if (document.getElementById(ID)) return;          // already up

  const bar = document.createElement('div');
  bar.id = ID;
  bar.setAttribute('role', 'status');
  bar.style.cssText = [
    'position:fixed', 'top:0', 'left:0', 'right:0', 'z-index:2147483647',
    'display:flex', 'align-items:center', 'justify-content:center', 'gap:14px',
    'padding:10px 16px', 'background:#1D4ED8', 'color:#fff',
    'font:600 13px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif',
    'box-shadow:0 2px 12px rgba(0,0,0,0.18)',
  ].join(';');

  const text = document.createElement('span');
  text.textContent = STALE_BUILD_MESSAGE;

  const reload = document.createElement('button');
  reload.type = 'button';
  reload.textContent = 'Reload';
  reload.style.cssText = [
    'padding:5px 14px', 'border:none', 'border-radius:6px',
    'background:#fff', 'color:#1D4ED8', 'font:700 12.5px/1 inherit',
    'cursor:pointer',
  ].join(';');
  reload.onclick = () => window.location.reload();

  /* Dismissible, because somebody may be in the middle of typing something
     they would rather finish and save first. Their next lazy chunk will bring
     it back -- the banner is a standing condition, not a one-time alert. */
  const close = document.createElement('button');
  close.type = 'button';
  close.setAttribute('aria-label', 'Dismiss');
  close.textContent = '✕';
  close.style.cssText = [
    'padding:4px 8px', 'border:none', 'background:transparent',
    'color:#C7D7FE', 'font:600 13px/1 inherit', 'cursor:pointer',
  ].join(';');
  close.onclick = () => bar.remove();

  bar.append(text, reload, close);
  document.body.appendChild(bar);
}

/**
 * Install once, at startup, before anything can lazy-load.
 *
 * Two sources, because vite:preloadError does not see everything. It fires
 * from Vite's preload helper, which wraps the imports Vite rewrote; an import
 * that reaches the network another way -- and Safari, which reports some of
 * these as a plain rejection -- arrives only as an unhandledrejection. The
 * second listener is the net under the first, and both funnel to the same
 * one-time banner.
 */
export function installStaleBuildNotice() {
  window.addEventListener('vite:preloadError', () => {
    // NOT preventDefault(). See the header: swallowing the throw replaces a
    // precise error with a meaningless one downstream.
    detected = true;
    showBanner();
  });

  window.addEventListener('unhandledrejection', (ev: PromiseRejectionEvent) => {
    if (!isStaleBuildError(ev.reason)) return;
    detected = true;
    showBanner();
  });
}
