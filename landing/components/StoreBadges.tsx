import Image from 'next/image';

/**
 * Official store artwork, downloaded unmodified from Apple Developer and Google Play.
 *
 * The two source files have different intrinsic canvas proportions: Google's PNG includes
 * transparent clear space around the badge while Apple's SVG does not. Giving Google a
 * wider image box makes the visible black badges land at the same height without cropping
 * or altering either asset -- both vendors explicitly prohibit modifying their artwork.
 *
 * These remain non-interactive until real product-page URLs exist. Shipping a dead link is
 * worse than honest status text, but the official guidelines require badges to link to the
 * store listing, so the domain should not go live in this state. Once listings exist, wrap
 * each image in its store URL and remove the shared "Coming soon" label.
 */
export function StoreBadges() {
  return (
    <div aria-label="Show Up is coming soon to the App Store and Google Play">
      <p className="mb-3 text-sm font-semibold text-body">Coming soon on</p>
      <ul className="flex flex-wrap items-center gap-3">
        {/* Apple asks to appear first when badges for multiple platforms share a row. */}
        <li className="flex h-12 items-center">
          <Image
            src="/store-badges/app-store.svg"
            alt="Download on the App Store"
            width={144}
            height={48}
            priority
          />
        </li>
        <li className="flex h-12 items-center">
          <Image
            src="/store-badges/google-play.png"
            alt="Get it on Google Play"
            width={162}
            height={63}
            priority
          />
        </li>
      </ul>
    </div>
  );
}
