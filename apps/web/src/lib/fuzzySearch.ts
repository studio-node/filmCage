// Lightweight, dependency-free fuzzy text matching for the equipment
// catalog search (the top-nav global search box and the Browse
// Equipment page's own search field share this). Case-insensitive
// and typo-tolerant: a query that's close to a target string —
// transposed, missing, extra, or wrong letters — still matches, and
// matches are scored so the closest ones can be shown first.
// Everything here runs over data already loaded into the browser; no
// network call, no database function, no migration needed for this
// to work.

function normalize(s: string): string {
  return s.trim().toLowerCase()
}

// Edit distance between two short strings, counting insert, delete,
// substitute, and — importantly — swapping two adjacent letters as a
// single edit ("optimal string alignment" distance, a restricted
// form of Damerau-Levenshtein). That last part matters more than it
// sounds: swapped adjacent letters ("cmaera", "teh") are one of the
// most common real typos, and plain Levenshtein would charge two
// edits for something a person would call "one mistake." Uses a
// full matrix rather than a rolling two-row version — these are
// single words/short phrases (item names, brands), never long
// enough for that to matter.
function editDistance(a: string, b: string): number {
  if (a === b) return 0
  const al = a.length
  const bl = b.length
  if (al === 0) return bl
  if (bl === 0) return al

  const d: number[][] = []
  for (let i = 0; i <= al; i++) {
    d.push(new Array(bl + 1).fill(0))
    d[i][0] = i
  }
  for (let j = 0; j <= bl; j++) d[0][j] = j

  for (let i = 1; i <= al; i++) {
    for (let j = 1; j <= bl; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1
      let val = Math.min(
        d[i - 1][j] + 1, // deletion
        d[i][j - 1] + 1, // insertion
        d[i - 1][j - 1] + cost // substitution
      )
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        val = Math.min(val, d[i - 2][j - 2] + 1) // adjacent transposition
      }
      d[i][j] = val
    }
  }
  return d[al][bl]
}

// How many edits we'll tolerate for a word of a given length. Very
// short words (<=2 letters) require an exact match — otherwise
// something like "sx" would typo-match half the catalog ("sd", "6x",
// "ex", ...). Medium words tolerate one slip, longer words tolerate
// two, since one or two wrong letters out of seven-plus is still
// clearly "the same word" to a person typing fast.
function maxEditsFor(length: number): number {
  if (length <= 2) return 0
  if (length <= 5) return 1
  return 2
}

// Score a single query word against a single target word. Lower is
// better; null means "doesn't match at all".
function scoreWord(query: string, target: string): number | null {
  if (!query || !target) return null
  if (target === query) return 0
  if (target.startsWith(query)) return 0.5 // e.g. "cam" while typing "camera"
  if (target.includes(query)) return 1
  const edits = editDistance(query, target)
  if (edits <= maxEditsFor(Math.min(query.length, target.length))) {
    return 2 + edits // typo match — still a match, ranked behind real ones
  }
  return null
}

export interface FuzzyMatch {
  score: number
}

// Matches a (possibly multi-word) query against a block of
// searchable text (already-joined name/brand/model/category/location
// fields). Every word in the query has to match *something* in the
// text — not necessarily in order — for the whole query to count, so
// "canon camra" matches "Canon EOS R6 Mark II Camera" even though
// neither query word is a substring of the full name.
export function fuzzyMatch(query: string, text: string): FuzzyMatch | null {
  const q = normalize(query)
  if (!q) return { score: 0 }
  const haystack = normalize(text)

  // Fast path: the whole query appears verbatim in the text — this
  // is what a plain substring search would already catch, and it's
  // always the best possible match.
  if (haystack.includes(q)) return { score: 0 }

  const queryWords = q.split(/\s+/).filter(Boolean)
  const targetWords = haystack.split(/[\s,./()-]+/).filter(Boolean)
  if (queryWords.length === 0 || targetWords.length === 0) return null

  let total = 0
  for (const qw of queryWords) {
    let best: number | null = null
    for (const tw of targetWords) {
      const s = scoreWord(qw, tw)
      if (s !== null && (best === null || s < best)) best = s
    }
    if (best === null) return null // this query word matched nothing anywhere
    total += best
  }
  return { score: total }
}

// Convenience for simple boolean filtering (e.g. Browse Equipment's
// grid filter, which doesn't need the score — just in or out).
export function fuzzyTest(query: string, text: string): boolean {
  return fuzzyMatch(query, text) !== null
}
