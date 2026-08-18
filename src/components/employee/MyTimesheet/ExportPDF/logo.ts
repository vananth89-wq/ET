import { supabase } from '../../../../lib/supabase';

/**
 * The tenant's logo, as a data URL, for the report header.
 *
 * react-pdf cannot fetch a URL at render time, so the bytes have to be in hand
 * before the document is built. Shared rather than page-local because both the
 * employee's own export and an approver's copy print the same letterhead, and a
 * report that carried the logo on one surface and not the other would look like
 * two different documents.
 *
 * Never throws. A report with no logo is still a correct report; no report is
 * not, and a broken image is not worth failing an export over.
 */
export async function loadLogoDataUrl(): Promise<string | null> {
  try {
    let src = '/logo.png';
    const { data: theme } = await supabase.rpc('get_theme_settings');
    if (theme?.nav_logo) src = theme.nav_logo as string;

    const res = await fetch(src);
    if (!res.ok) return null;
    const blob = await res.blob();
    // A 404 handled by the SPA shell returns index.html with a 200. Without
    // this check that HTML would be handed to react-pdf as an "image".
    if (!blob.type.startsWith('image/')) return null;

    return await new Promise<string | null>(resolve => {
      const fr = new FileReader();
      fr.onload  = () => resolve(typeof fr.result === 'string' ? fr.result : null);
      fr.onerror = () => resolve(null);
      fr.readAsDataURL(blob);
    });
  } catch {
    return null;
  }
}
