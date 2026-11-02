import { performance } from 'node:perf_hooks';
import { writeFileSync } from 'node:fs';
import fixture from '../../../test/fixtures/roulette-benchmark.json';
import { rankRoulette, type TasteSignal } from './koreader-roulette-ranker';
import type { DiscoveryBook } from './koreader-discovery.service';
describe('Personal recommendation ranking and offline proxy benchmark', () => {
  it('adapts immediately to positive and negative feedback without shared users', () => {
    const candidates = [
      { title: 'Space travel', authors: [], genres: ['Science fiction'] },
      { title: 'Courtship', authors: [], genres: ['Romance'] },
    ];
    const liked = { title: 'A favorite', authors: [], genres: ['Romance'] };
    expect(rankRoulette(candidates, [{ book: liked, weight: 2 }])[0].title).toBe('Courtship');
    expect(rankRoulette(candidates, [{ book: liked, weight: -2 }])[0].title).toBe('Space travel');
  });
  it('uses individual learning only with sufficient positive AND negative labels', () => {
    const signals: TasteSignal[] = fixture.slice(0, 3).map((book) => ({ book, weight: 2 }));
    expect(rankRoulette(fixture.slice(3), signals)[0].model).toBe('personal-tfidf-mmr');
    signals.push(...fixture.slice(9, 12).map((book) => ({ book, weight: -2 })));
    expect(rankRoulette(fixture.slice(3), signals)[0].model).toBe('personal-logistic-tfidf-mmr');
  });
  it('keeps the same top five and exploratory choice when computing only the visible-card window', () => {
    const signals = fixture.slice(0, 6).map((book, i) => ({ book, weight: i < 3 ? 2 : -2 }));
    for (const mode of ['genre', 'content', 'hybrid'] as const) {
      expect(rankRoulette(fixture.slice(6), signals, mode, 5)).toEqual(rankRoulette(fixture.slice(6), signals, mode).slice(0, 5));
    }
  });
  it('benchmarks cold, sparse and warm profiles against held-out literary topic labels', () => {
    const topics = [...new Set(fixture.map((b) => b.topic))];
    const metrics = [];
    for (const mode of ['genre', 'content', 'hybrid'] as const)
      for (const size of [0, 1, 3]) {
        let precision = 0,
          ndcg = 0,
          diversity = 0;
        const latency: number[] = [];
        for (let i = 0; i < topics.length; i++) {
          const positives = fixture.filter((b) => b.topic === topics[i]).slice(0, size),
            negatives = fixture.filter((b) => b.topic === topics[(i + 1) % topics.length]).slice(0, size);
          const seeds = new Set([...positives, ...negatives].map((b) => b.title));
          const candidates = fixture.filter((b) => !seeds.has(b.title));
          const signals = [...positives.map((book) => ({ book, weight: 2 })), ...negatives.map((book) => ({ book, weight: -2 }))];
          const start = performance.now();
          const ranked = rankRoulette(candidates, signals, mode);
          latency.push(performance.now() - start);
          const relevant = new Set(candidates.filter((b) => b.topic === topics[i]).map((b) => b.title));
          precision += ranked.slice(0, 5).filter((b) => relevant.has(b.title)).length / 5;
          const gain = (items: DiscoveryBook[]) => items.slice(0, 10).reduce((s, b, j) => s + (relevant.has(b.title) ? 1 / Math.log2(j + 2) : 0), 0);
          ndcg += gain(ranked) / gain(candidates.filter((b) => relevant.has(b.title)));
          diversity += new Set(ranked.slice(0, 10).flatMap((b) => b.genres ?? [])).size;
        }
        metrics.push({
          mode,
          profile: size === 0 ? 'cold' : size === 1 ? 'sparse' : 'warm',
          precisionAt5: precision / topics.length,
          ndcgAt10: ndcg / topics.length,
          distinctGenresAt10: diversity / topics.length,
          meanMs: latency.reduce((a, b) => a + b, 0) / latency.length,
          maxMs: Math.max(...latency),
        });
      }
    // Synthetic topic relevance is a reproducible regression proxy, not measured reader satisfaction.
    expect(metrics.find((m) => m.mode === 'hybrid' && m.profile === 'sparse')!.precisionAt5).toBeGreaterThanOrEqual(0.6);
    if (process.env.ROULETTE_BENCHMARK_OUTPUT)
      writeFileSync(
        process.env.ROULETTE_BENCHMARK_OUTPUT,
        JSON.stringify(
          {
            fixtureBooks: fixture.length,
            personas: topics.length,
            labelBasis: 'Manually grouped literary topics; synthetic personas, held-out titles, no user preference claims',
            metrics,
          },
          null,
          2,
        ),
      );
  });
});
