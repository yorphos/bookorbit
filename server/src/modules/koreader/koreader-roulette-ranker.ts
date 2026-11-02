import type { DiscoveryBook } from './koreader-discovery.service';
export type TasteSignal = { book: DiscoveryBook; weight: number };
type Vector = Map<string, number>;
const STOP = new Set('the a an and or of in to for with by on is was from at as this that it its'.split(' '));
function terms(book: DiscoveryBook): Vector {
  const result: Vector = new Map();
  const add = (key: string, value: number) => result.set(key, (result.get(key) ?? 0) + value);
  for (const author of book.authors ?? []) add('author:' + author.toLowerCase(), 3);
  for (const genre of (book.genres ?? []).slice(0, 30)) add('genre:' + genre.toLowerCase(), 4);
  for (const word of ((book.title ?? '') + ' ' + (book.description ?? ''))
    .toLowerCase()
    .match(/[\p{L}\p{N}]{3,}/gu)
    ?.slice(0, 240) ?? [])
    if (!STOP.has(word)) add(word, 1);
  return result;
}
const dot = (a: Vector, b: Vector) => {
  let sum = 0;
  for (const [k, v] of a) sum += v * (b.get(k) ?? 0);
  return sum;
};
function normalize(a: Vector) {
  const norm = Math.sqrt(dot(a, a));
  if (norm) for (const [k, v] of a) a.set(k, v / norm);
  return a;
}
export function rankRoulette(candidates: DiscoveryBook[], signals: TasteSignal[], mode: 'genre' | 'content' | 'hybrid' = 'hybrid', limit = 30) {
  const documents = [...candidates, ...signals.map((s) => s.book)].map(terms),
    df = new Map<string, number>();
  for (const doc of documents) for (const key of doc.keys()) df.set(key, (df.get(key) ?? 0) + 1);
  const vectors = documents.map((doc) =>
    normalize(
      new Map([...doc].map(([key, value]) => [key, (1 + Math.log(value)) * (1 + Math.log((documents.length + 1) / ((df.get(key) ?? 0) + 1)))])),
    ),
  );
  const signalVectors = vectors.slice(candidates.length),
    profile: Vector = new Map(),
    weights: Vector = new Map();
  signals.forEach((signal, i) => {
    for (const [key, value] of signalVectors[i]) profile.set(key, (profile.get(key) ?? 0) + signal.weight * value);
  });
  normalize(profile);
  // A per-user regularized logistic ranker. No pooled interactions or private-user features.
  const explicit = signals.map((s, i) => ({ s, v: signalVectors[i] })).filter((x) => Math.abs(x.s.weight) >= 2);
  const learned = explicit.filter((x) => x.s.weight > 0).length >= 3 && explicit.filter((x) => x.s.weight < 0).length >= 3;
  if (learned)
    for (let epoch = 0; epoch < 12; epoch++)
      for (const { s, v } of explicit) {
        const error = (s.weight > 0 ? 1 : 0) - 1 / (1 + Math.exp(-dot(weights, v)));
        for (const [key, value] of v) weights.set(key, (weights.get(key) ?? 0) * 0.999 + 0.3 * error * value);
      }
  const scored = candidates.map((book, i) => {
    let affinity = dot(vectors[i], profile);
    if (mode === 'genre') {
      affinity = signals.reduce((sum, s) => sum + s.weight * (book.genres ?? []).filter((g) => (s.book.genres ?? []).includes(g)).length, 0);
    }
    const score = mode === 'hybrid' && learned ? 0.55 * affinity + 0.45 * Math.tanh(dot(weights, vectors[i])) : affinity;
    return { book, index: i, score, exploratory: false };
  });
  const selected: typeof scored = [];
  const noveltyCache = new Map<number, number>();
  while (scored.length && selected.length < Math.max(0, Math.min(30, limit))) {
    const explore = mode === 'hybrid' && selected.length > 0 && selected.length % 5 === 4;
    const hasNonnegative = scored.some((item) => item.score >= 0);
    scored.sort((a, b) => {
      const score = (x: typeof a) =>
        mode !== 'hybrid'
          ? x.score
          : (explore ? 0.2 : 0.8) * x.score - (explore ? 0.8 : 0.2) * (noveltyCache.get(x.index) ?? 0) - (hasNonnegative && x.score < 0 ? 2 : 0);
      return score(b) - score(a) || a.index - b.index;
    });
    const next = scored.shift()!;
    if (explore) next.exploratory = true;
    selected.push(next);
    for (const remaining of scored) {
      noveltyCache.set(remaining.index, Math.max(noveltyCache.get(remaining.index) ?? 0, dot(vectors[remaining.index], vectors[next.index])));
    }
  }
  return selected.map((item) => {
    // Explanations are needed only for results that survive reranking.
    let closest: { s: TasteSignal; sim: number } | undefined;
    if (!item.exploratory)
      signals.forEach((s, j) => {
        if (s.weight <= 0) return;
        const sim = dot(vectors[item.index], signalVectors[j]);
        if (!closest || sim > closest.sim) closest = { s, sim };
      });
    const common = (item.book.genres ?? []).filter((g) => closest?.s.book.genres?.includes(g));
    const why = item.exploratory
      ? 'An exploratory pick to broaden your discoveries'
      : closest && closest.sim > 0.05
        ? common.length
          ? 'Shares ' + common.slice(0, 2).join(', ') + ' with ' + closest.s.book.title
          : 'Similar metadata to ' + closest.s.book.title
        : 'Exploring beyond your current tastes';
    return {
      ...item.book,
      recommendationWhy: why,
      recommendationScore: item.score,
      model: learned ? 'personal-logistic-tfidf-mmr' : 'personal-tfidf-mmr',
    };
  });
}
