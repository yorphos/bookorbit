import { of, lastValueFrom } from 'rxjs';
import { etagMatches, KoreaderEtagInterceptor, koreaderEtag } from './koreader-etag.interceptor';

function context(method: string, ifNoneMatch?: string) {
  const headers: Record<string, string> = {};
  const reply = {
    sent: false,
    statusCode: 200,
    header: vi.fn((name: string, value: string) => (headers[name] = value)),
    status: vi.fn(function (this: { statusCode: number }, code: number) {
      reply.statusCode = code;
      return reply;
    }),
  };
  const request = { method, headers: ifNoneMatch ? { 'if-none-match': ifNoneMatch } : {} };
  const ctx = { switchToHttp: () => ({ getRequest: () => request, getResponse: () => reply }) };
  return { ctx: ctx as never, reply, headers };
}

describe('KoreaderEtagInterceptor', () => {
  const interceptor = new KoreaderEtagInterceptor();
  it('ignores per-response timestamps when tagging a body', () => {
    expect(koreaderEtag({ a: 1, generatedAt: 'x' })).toBe(koreaderEtag({ a: 1, generatedAt: 'y' }));
    expect(koreaderEtag({ a: 1 })).not.toBe(koreaderEtag({ a: 2 }));
  });
  it('tags a GET and answers an unchanged repeat with an empty 304', async () => {
    const body = { items: [1, 2] };
    const first = context('GET');
    expect(await lastValueFrom(interceptor.intercept(first.ctx, { handle: () => of(body) }))).toBe(body);
    const tag = first.headers.ETag;
    expect(tag).toMatch(/^W\/"/);
    const repeat = context('GET', tag);
    expect(await lastValueFrom(interceptor.intercept(repeat.ctx, { handle: () => of(body) }))).toBe('');
    expect(repeat.reply.statusCode).toBe(304);
  });
  it('leaves writes and handlers that send their own reply alone', async () => {
    const post = context('POST');
    expect(await lastValueFrom(interceptor.intercept(post.ctx, { handle: () => of({ ok: true }) }))).toEqual({ ok: true });
    expect(post.reply.header).not.toHaveBeenCalled();
    const stream = context('GET');
    stream.reply.sent = true;
    expect(await lastValueFrom(interceptor.intercept(stream.ctx, { handle: () => of(undefined) }))).toBeUndefined();
    expect(stream.reply.header).not.toHaveBeenCalled();
  });
  it('matches strong and weak forms of the same tag', () => {
    expect(etagMatches('W/"abc"', 'W/"abc"')).toBe(true);
    expect(etagMatches('"abc", "def"', 'W/"def"')).toBe(true);
    expect(etagMatches('"zzz"', 'W/"abc"')).toBe(false);
  });
});
