// Sync-loaded before the body parses so the chosen language is in
// effect before any text paints. Runs once per page.
document.documentElement.dataset.lang =
  localStorage.getItem("lilac-7guis-lang") || "ja";
