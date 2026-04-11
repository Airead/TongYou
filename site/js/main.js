/* ============================================================
   TongYou — GitHub Pages Script
   Scroll-fade animation + GitHub Release version fetch
   ============================================================ */

(function () {
  "use strict";

  // ---------- Intersection Observer for fade-in ----------
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("visible");
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.12 }
  );

  document.querySelectorAll(".fade-in").forEach((el) => observer.observe(el));

  // ---------- Fetch latest release from GitHub API ----------
  const REPO = "Airead/TongYou";
  const versionBadge = document.getElementById("version-badge");
  const downloadBtn = document.getElementById("download-btn");

  if (versionBadge || downloadBtn) {
    fetch(`https://api.github.com/repos/${REPO}/releases/latest`)
      .then((res) => {
        if (!res.ok) throw new Error(res.status);
        return res.json();
      })
      .then((release) => {
        const tag = release.tag_name;

        if (versionBadge) {
          versionBadge.textContent = `Latest: ${tag}`;
        }

        const dmgAsset = release.assets.find((a) => a.name.endsWith(".dmg"));
        const fallback = release.html_url;

        if (downloadBtn) {
          downloadBtn.href = dmgAsset
            ? dmgAsset.browser_download_url
            : fallback;
        }
      })
      .catch(() => {
        // Silently fall back — buttons keep default Releases link
      });
  }
})();
