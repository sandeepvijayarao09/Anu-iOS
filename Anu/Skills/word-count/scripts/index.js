// Counts words, characters, sentences and lines. Reading time at 230 words a minute.
function ai_edge_gallery_get_result(data) {
  let text = data;
  try {
    const parsed = JSON.parse(data);
    if (parsed && typeof parsed.text === "string") text = parsed.text;
  } catch (e) { /* plain text */ }
  text = String(text);
  const trimmed = text.trim();
  const words = trimmed === "" ? 0 : trimmed.split(/\s+/).length;
  const sentences = trimmed === "" ? 0 : (trimmed.match(/[^.!?]+([.!?]+|$)/g) || []).filter((s) => s.trim() !== "").length;
  const lines = text === "" ? 0 : text.split(/\r\n|\r|\n/).length;
  return JSON.stringify({
    result: {
      words: words,
      characters: Array.from(text).length,
      charactersWithoutSpaces: Array.from(text.replace(/\s/g, "")).length,
      sentences: sentences,
      lines: lines,
      readingMinutes: words === 0 ? 0 : Math.max(1, Math.round(words / 230)),
    },
  });
}
