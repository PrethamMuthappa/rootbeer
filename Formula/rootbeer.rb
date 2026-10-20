# Homebrew formula for RootBeer. This repo doubles as its own tap:
#   brew tap prethammuthappa/rootbeer https://github.com/PrethamMuthappa/rootbeer
#   brew trust --formula prethammuthappa/rootbeer/rootbeer   # Homebrew 7 requires trusting non-official taps
#   brew install rootbeer
# RootBeer is built from source on the user's Mac, so it needs no Developer ID signature.
class Rootbeer < Formula
  desc "Native macOS app for safely managing Homebrew packages"
  homepage "https://github.com/PrethamMuthappa/rootbeer"
  url "https://github.com/PrethamMuthappa/rootbeer/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "31838836860d02590fb7c0e5199a170c630ede7a7dd0f5eaf6171f195747f439"
  license "MIT"
  head "https://github.com/PrethamMuthappa/rootbeer.git", branch: "main"

  depends_on macos: :sonoma

  def install
    ENV["ROOTBEER_VERSION"] = version.to_s
    # Homebrew builds inside its own sandbox, and SwiftPM can't nest another one.
    ENV["ROOTBEER_SWIFT_FLAGS"] = "--disable-sandbox"
    system "./Scripts/build-app.sh"
    prefix.install "build/RootBeer.app"
  end

  def caveats
    <<~EOS
      To open RootBeer from Launchpad and Spotlight, link it into Applications:
        ln -sf #{opt_prefix}/RootBeer.app /Applications/RootBeer.app

      To uninstall, quit RootBeer first; it won't remove itself while running.
    EOS
  end

  test do
    app = prefix/"RootBeer.app"
    assert_predicate app/"Contents/MacOS/RootBeer", :executable?
    assert_equal "io.github.prethammuthappa.rootbeer",
                 shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' #{app}/Contents/Info.plist").strip
  end
end
