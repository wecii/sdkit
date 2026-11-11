class Sdkit < Formula
  desc "Spec-driven development workflow and guards for AI coding agents (Claude Code, Codex, OpenCode, Cursor, Gemini)"
  homepage "https://github.com/wecii/sdkit"
  url "https://github.com/wecii/sdkit.git", using: :git, tag: "v1.6.0", revision: "165487c8fe175a58c997f92237f528e6b46833ad"
  version "1.6.0"
  head "https://github.com/wecii/sdkit.git", using: :git, branch: "master"

  depends_on "jq"
  depends_on "node" # the OpenSpec CLI (npm) that the workflow drives

  def install
    # the whole kit stays together: scripts find their siblings relative to themselves
    libexec.install Dir["*", ".claude-plugin"]
    bin.install_symlink libexec/"bin/sdkit"
  end

  def caveats
    <<~EOS
      Set a repo up (once per repo, by one person):
        cd your-repo && sdkit init
      OpenSpec is part of the workflow. If it is not installed yet:
        sdkit init --install-openspec     (runs: npm install -g @fission-ai/openspec)
      Check a repo any time:  sdkit doctor
      Upgrade a repo after "brew upgrade":  sdkit upgrade
    EOS
  end

  test do
    assert_match "sdkit", shell_output("#{bin}/sdkit version")
    assert_match(/^#{Regexp.escape(libexec)}$/, shell_output("#{bin}/sdkit where").strip)
  end
end
