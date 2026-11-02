/**
 * Compares plugin/app versions. Builds of the yorphos fork append `+yrp.N` (plugin) or
 * `-yrp.N` (app) to the upstream version they are based on; N breaks ties between builds of
 * the same upstream version, and a plain upstream version counts as N = 0.
 */
export function isSemverNewer(candidate: string | null | undefined, current: string | null | undefined): boolean | null {
  const parsedCandidate = parseSemver(candidate);
  const parsedCurrent = parseSemver(current);
  if (!parsedCandidate || !parsedCurrent) return null;
  for (let i = 0; i < parsedCandidate.length; i++) {
    if (parsedCandidate[i] !== parsedCurrent[i]) return parsedCandidate[i]! > parsedCurrent[i]!;
  }
  return false;
}

/** The upstream `major.minor.patch` and the fork build number (0 when absent). */
export function parseSemver(version: string | null | undefined): [number, number, number, number] | null {
  if (!version) return null;
  const match = version.match(/^v?(\d+)\.(\d+)\.(\d+)/);
  if (!match) return null;
  const fork = version.match(/[+-]yrp\.(\d+)$/);
  return [Number(match[1]!), Number(match[2]!), Number(match[3]!), fork ? Number(fork[1]!) : 0];
}
