import { Svg, Path, Circle, Rect, Polyline, Polygon, Line } from '@react-pdf/renderer';

/**
 * The eight summary-tile glyphs, drawn as vectors.
 *
 * NOT emoji. react-pdf's built-in Helvetica has no emoji table and no geometric
 * symbols either — 🕒 📈 ▲ ● ★ ✓ all render as overlapping mojibake, verified by
 * rendering them. The alternative to drawing them is registering a font with an
 * emoji table, which would add megabytes to a chunk whose whole design is that
 * nobody downloads it until they press Export.
 *
 * Stroked, never filled, so each glyph takes the colour of its tile's rail and
 * the tiles stay a set rather than a collection.
 */
export type IconName =
  | 'clock' | 'trend' | 'gauge' | 'folder'
  | 'calendar' | 'suitcase' | 'star' | 'over';

export function KPIIcon({ name, color, size = 11 }: { name: IconName; color: string; size?: number }) {
  const S = { stroke: color, strokeWidth: 1.9, fill: 'none' } as const;
  return (
    <Svg viewBox="0 0 24 24" width={size} height={size}>
      {name === 'clock' && (<>
        <Circle cx="12" cy="12" r="9" {...S} />
        <Polyline points="12,6.5 12,12 16,14" {...S} />
      </>)}

      {name === 'trend' && (<>
        <Polyline points="3,17 9,11 13,15 21,6" {...S} />
        <Polyline points="15,6 21,6 21,12" {...S} />
      </>)}

      {/* A filled wedge, not a gauge. The arc-and-needle version rendered as an
          illegible squiggle at 11pt — verified, not assumed. A proportion of a
          circle survives being small, which is the only test that matters. */}
      {name === 'gauge' && (<>
        <Path d="M12 3 A 9 9 0 0 1 21 12 L12 12 Z" fill={color} stroke="none" />
        <Circle cx="12" cy="12" r="9" {...S} />
      </>)}

      {name === 'folder' && (
        <Path d="M3 6.5 h6 l2 2.5 h10 v10.5 h-18 z" {...S} />
      )}

      {name === 'calendar' && (<>
        <Rect x="3.5" y="5.5" width="17" height="15" rx="2" {...S} />
        <Line x1="3.5" y1="10" x2="20.5" y2="10" {...S} />
        <Line x1="8" y1="3" x2="8" y2="7" {...S} />
        <Line x1="16" y1="3" x2="16" y2="7" {...S} />
      </>)}

      {name === 'suitcase' && (<>
        <Rect x="3" y="8" width="18" height="12" rx="2" {...S} />
        <Path d="M9 8 V5.5 h6 V8" {...S} />
      </>)}

      {name === 'star' && (
        <Polygon points="12,3 14.6,9.2 21,9.8 16.2,14.2 17.6,20.6 12,17.3 6.4,20.6 7.8,14.2 3,9.8 9.4,9.2" {...S} />
      )}

      {/* An arrow leaving the ceiling — over the line, not a warning triangle,
          which would read as an error. Recording more than planned is not one. */}
      {name === 'over' && (<>
        <Line x1="3.5" y1="6" x2="20.5" y2="6" {...S} />
        <Polyline points="12,21 12,10" {...S} />
        <Polyline points="7.5,14.5 12,10 16.5,14.5" {...S} />
      </>)}
    </Svg>
  );
}
