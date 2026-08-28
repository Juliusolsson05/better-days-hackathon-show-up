/**
 * "Coming soon" markers for the two app stores.
 *
 * Deliberately NOT the official App Store / Google Play badges. Both are trademarked
 * artwork that Apple and Google require you to use unmodified and from their own asset
 * kits, and a hand-drawn approximation of either logo is a worse outcome than no logo at
 * all -- it looks off to anyone who knows the real one, and it is the kind of thing that
 * gets a listing rejected. Swap these for the real badges from Apple's Marketing Resources
 * and Google's Play Badge generator once the apps are actually listed.
 *
 * Rendered as spans rather than anchors or buttons: there is nowhere to go yet. A disabled
 * button invites a click that does nothing, and a link to a store page that does not exist
 * is worse. This states availability, so it is text.
 */
export function StoreBadges() {
  return (
    <ul className="flex flex-wrap gap-3">
      {['App Store', 'Google Play'].map((store) => (
        <li key={store}>
          <span className="flex flex-col rounded-3xl bg-canvas px-6 py-3">
            <span className="text-xs font-semibold text-muted">
              Coming soon
            </span>
            <span className="text-base font-semibold text-ink">{store}</span>
          </span>
        </li>
      ))}
    </ul>
  );
}
