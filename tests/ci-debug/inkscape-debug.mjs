// Debug harness that mimics `findInkscape()` from tests/svg-stroke-removal.test.ts
// and captures every detail of how the `inkscape` binary is located on Windows.
import { spawnSync } from 'node:child_process'
import * as fs from 'node:fs'
import * as os from 'node:os'
import path from 'node:path'

const log = msg => console.log(`[debug] ${msg}`)

log(`Platform: ${process.platform}`)
log(`PATH:\n${process.env.PATH}`)
log(`os.tmpdir(): ${os.tmpdir()}`)

// 1. Does the choco shim exist on disk?
const shim = path.join('C:', 'ProgramData', 'chocolatey', 'bin', 'inkscape.exe')

log(`Choco shim exists at ${shim}: ${fs.existsSync(shim)}`)

if (fs.existsSync(shim)) {
	const real = path.join('C:', 'Program Files', 'Inkscape', 'bin', 'inkscape.exe')

	log(`Real inkscape exists at ${real}: ${fs.existsSync(real)}`)
}

// 2. Where does `where inkscape` / `Get-Command` resolve?
for (const cmd of ['where', 'Get-Command']) {
	try {
		const r = spawnSync(
			'powershell.exe',
			[
				'-NoProfile',
				'-Command',
				'Get-Command inkscape -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source',
			],
			{ encoding: 'utf8', timeout: 30000 },
		)

		log(
			`Get-Command inkscape -> status=${r.status} stdout=${JSON.stringify(r.stdout)} stderr=${JSON.stringify(r.stderr)}`,
		)
	} catch (e) {
		log(`Get-Command threw: ${e.message}`)
	}
}

// 3. The exact reproduction of findInkscape()'s first candidate.
const candidates = [
	['inkscape'],
	['flatpak', 'run', `--filesystem=${os.tmpdir()}`, 'org.inkscape.Inkscape'],
]

for (const candidate of candidates) {
	const t0 = Date.now()
	let result

	try {
		result = spawnSync(candidate[0], [...candidate.slice(1), '--version'], {
			encoding: 'utf8',
			timeout: 30000,
		})
	} catch (e) {
		log(`spawnSync(${candidate[0]}) THREW: ${e.message}`)
		continue
	}

	const elapsed = Date.now() - t0

	log(
		`spawnSync(${candidate[0]}) -> status=${result.status} elapsed=${elapsed}ms ` +
			`error=${result.error ? result.error.code || result.error.message : 'none'} ` +
			`signal=${result.signal}`,
	)
	log(`  stdout=${JSON.stringify(result.stdout)}`)
	log(`  stderr=${JSON.stringify(result.stderr)}`)
	const ok = result.status === 0 && result.stdout.includes('Inkscape')

	log(`  => matches candidate (status===0 && stdout includes 'Inkscape'): ${ok}`)
}

log('DONE')
