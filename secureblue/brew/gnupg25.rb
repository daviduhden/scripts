class Gnupg25 < Formula
  desc "GNU Privacy Guard 2.5.x development branch (parallel install with PQ support)"
  homepage "https://gnupg.org/"
  url "https://gnupg.org/ftp/gcrypt/gnupg/gnupg-2.5.14.tar.bz2"
  sha256 "25a622e625a1cc9078b5e3f7adf2bd02b86759170e2fbb8542bca8e907214610"
  license "GPL-3.0-or-later"

  # 2.5.x is the development series leading to the next stable 2.6
  # and includes post-quantum support (Kyber via composite ECC+Kyber).
  # We keep this as a parallel install to the stable 2.4.x line.
  #
  # See: GnuPG 2.5.x release notes and PQC tracking tasks.

  # See the LICENSE file at the top of the project tree for copyright
  # and license details.  

  # This formula is intended to coexist with the stable "gnupg" formula.
  # By marking it as keg_only, it will not be linked into the main PATH
  # unless the user explicitly adjusts PATH or runs `brew link --force`.
  keg_only "Parallel install of the GnuPG 2.5.x development branch (not linked into PATH by default)"

  # Track the 2.5.x series on the official download directory.
  livecheck do
    url "https://gnupg.org/ftp/gcrypt/gnupg/"
    regex(/href=.*?gnupg[._-]v?(2\.5\.\d+)\.t/i)
  end

  depends_on "pkgconf" => :build
  depends_on "gnutls"
  depends_on "libassuan"
  depends_on "libgcrypt"
  depends_on "libgpg-error"
  depends_on "libksba"
  depends_on "libusb"
  depends_on "npth"
  depends_on "pinentry"
  depends_on "readline"

  uses_from_macos "bzip2"
  uses_from_macos "openldap"
  uses_from_macos "sqlite"
  uses_from_macos "zlib"

  on_macos do
    depends_on "gettext"
  end

  # These casks ship overlapping GnuPG binaries and GUI components,
  # so we keep the same conflicts as the main gnupg formula.
  conflicts_with cask: "gpg-suite"
  conflicts_with cask: "gpg-suite-no-mail"
  conflicts_with cask: "gpg-suite-pinentry"
  conflicts_with cask: "gpg-suite@nightly"

  def install
    libusb = Formula["libusb"]
    # GnuPG's build system expects this libusb include path layout.
    ENV.append "CPPFLAGS", "-I#{libusb.opt_include}/libusb-#{libusb.version.major_minor}"

    mkdir "build" do
      system "../configure", "--disable-silent-rules",
                             "--enable-all-tests",
                             "--sysconfdir=#{etc}",
                             "--with-pinentry-pgm=#{Formula["pinentry"].opt_bin}/pinentry",
                             "--with-readline=#{Formula["readline"].opt_prefix}",
                             *std_configure_args
      system "make"
      system "make", "check"
      system "make", "install"
    end

    # Configure scdaemon as recommended by upstream developers
    # https://dev.gnupg.org/T5415#145864
    if OS.mac?
      # Write to buildpath first and then install to avoid clobbering any
      # existing configuration files in pkgetc.
      (buildpath/"scdaemon.conf").write <<~CONF
        disable-ccid
      CONF
      pkgetc.install "scdaemon.conf"
    end
  end

  def post_install
    # Ensure the runtime directory exists and restart gpg-agent so that
    # new binaries and configuration are picked up.
    (var/"run").mkpath
    quiet_system "killall", "gpg-agent"
  end

  test do
    # Use an isolated GNUPGHOME so tests do not interfere with any
    # user keys and so they are fully reproducible.
    gnupghome = testpath/"gnupg-homedir"
    gnupghome.mkpath
    env = { "GNUPGHOME" => gnupghome.to_s }

    # GnuPG 2.5.x supports the special algo string "pqc" with
    # --quick-gen-key, which creates a primary key plus a
    # quantum-resistant encryption subkey (ECC+Kyber).
    #
    # Here we:
    #   1. Generate a keypair using the "pqc" algorithm.
    #   2. Encrypt a small test file to that key.
    #   3. Decrypt it again and verify the plaintext.
    #
    # This ensures that the PQ (Kyber) capabilities are actually usable,
    # instead of only testing classic RSA.

    # 1) Generate a PQC-capable key non-interactively.
    system env, bin/"gpg",
           "--batch",
           "--passphrase", "",
           "--quick-gen-key", "PQC Test <pqc@example.com>",
           "pqc", "default", "1d"

    # 2) Encrypt a file to the PQC key.
    (testpath/"plaintext.txt").write "Hello World!"
    system env, bin/"gpg",
           "--batch", "--yes",
           "--encrypt",
           "--recipient", "pqc@example.com",
           "plaintext.txt"

    assert_predicate testpath/"plaintext.txt.gpg", :exist?

    # 3) Decrypt it again and check the content.
    decrypted = testpath/"decrypted.txt"
    system env, bin/"gpg",
           "--batch", "--yes",
           "--passphrase", "",
           "--output", decrypted.to_s,
           "--decrypt", "plaintext.txt.gpg"

    assert_equal "Hello World!", decrypted.read
  ensure
    # Cleanly shut down the agent so the test does not leave background
    # processes running.
    system env, bin/"gpgconf", "--kill", "gpg-agent"
  end
end
