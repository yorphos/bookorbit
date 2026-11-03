// This build is a modified BookOrbit. The image build sets the version it was built
// from and the day it was built, so Legal Notices can link the exact source.
export const FORK_REPOSITORY_URL = 'https://github.com/yorphos/bookorbit'

const version = String(import.meta.env.VITE_FORK_VERSION ?? '').trim()
const modified = String(import.meta.env.VITE_FORK_MODIFIED ?? '').trim()

export const forkSource = {
  version,
  modified,
  href: version ? `${FORK_REPOSITORY_URL}/tree/${version}` : FORK_REPOSITORY_URL,
}
