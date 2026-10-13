"""Plan a release locally; execution is explicit and restricted to manual CI."""
import argparse
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / 'release'))
import release_contract as contract
import ci_prepare
import release
import tap_update

SIGNING = ['MACOS_CERTIFICATE', 'MACOS_CERTIFICATE_PASSWORD', 'MACOS_SIGNING_IDENTITY', 'MACOS_TEAM_ID']
NOTARY = ['APPLE_NOTARIZATION_KEY_ID', 'APPLE_NOTARIZATION_ISSUER_ID', 'APPLE_NOTARIZATION_PRIVATE_KEY']


def plan(root, config, version, build, publish=False):
    steps = []
    for arch in ('universal',):
        artifact = str(root / 'dist/release' / arch / contract.artifact_name(config, version, arch))
        steps += [
            {'step': 'package', 'architecture': arch,
             'argv': ['./scripts/app.py', 'package', '--version', version, '--build', build,
                      '--arch', arch, '--sign', 'developer-id', '--output', str(root / 'dist/release' / arch)]},
            {'step': 'notarize', 'architecture': arch, 'artifact': artifact,
             'argv': ['xcrun', 'notarytool', 'submit', artifact, '--key', '$TEMP_AUTH_KEY_P8',
                      '--key-id', '$APPLE_NOTARIZATION_KEY_ID', '--issuer', '$APPLE_NOTARIZATION_ISSUER_ID',
                      '--wait', '--timeout', '30m', '--output-format', 'json']},
            {'step': 'staple', 'architecture': arch, 'argv': ['xcrun', 'stapler', 'staple', artifact]},
            {'step': 'verify-final-artifact', 'architecture': arch,
             'checks': ['Apple Accepted', 'stapler validate', 'mounted App payload', 'Developer ID / Team / runtime / timestamp', 'final SHA256']},
        ]
    if publish:
        steps += [{'step': 'publish', 'repository': config['repository'], 'tag': 'v' + version,
                   'checks': ['repository public before building', 'clean exact source', 'new immutable version or matching public reuse',
                              'draft uploaded bytes match', 'anonymous final download']},
                  {'step': 'update-cask', 'repository': 'mayflies-app/homebrew-tap', 'branch': 'main',
                   'path': 'Casks/' + config['caskToken'] + '.rb', 'checks': ['actual public universal DMG SHA256', 'only target cask commit']}]
    return {'mode': 'dry-run', 'executed': False, 'version': version, 'build': build,
            'source': '$GITHUB_SHA at execution', 'publish': publish,
            'requiredSecrets': SIGNING + NOTARY + (['HOMEBREW_TAP_TOKEN'] if publish else []),
            'credentialsValidated': False, 'steps': steps}


def execute(root, config, version, build, publish):
    contract.require_ci_remote(True, True)
    source = os.environ.get('GITHUB_SHA', '')
    if not contract.COMMIT.fullmatch(source):
        raise ValueError('Execution requires the full GITHUB_SHA')
    state = contract.source_state(root, source)
    if state['dirty']:
        raise ValueError('Release execution requires a clean checkout')
    if publish:
        metadata = release.github_json('repos/' + config['repository'])
        if metadata.get('visibility') != 'public':
            raise ValueError('Public publication requires a public release repository')
    ci_prepare.verify_toolchain()
    flags = ['preflight', '--config', str(root / 'macos-app.json'), '--version', version,
             '--build', build, '--source-commit', source, '--sign-mode', 'developer-id',
             '--request-notarization', '--ci', '--allow-remote', '--online']
    if publish:
        flags += ['--request-publish', '--request-tap']
    preflight = release.main(flags)
    if not preflight['reuse']:
        ci_prepare.prepare(root / 'macos-app.json', version, build, 'universal',
                           root / 'dist/release/universal', signed=True, notarized=True)
        contract.collect(config, root / 'dist/release', version, source, promotion=True)
    if publish:
        proof = release.publish(config, version, source, root / 'dist/release')
        tap = root / '.build/release-tap'
        if tap.exists():
            raise ValueError('Tap execution needs a fresh checkout')
        tap.parent.mkdir(parents=True, exist_ok=True)
        # Supply the tap token through Git's credential helper environment, never the URL.
        env = dict(os.environ, GH_TOKEN=os.environ['HOMEBREW_TAP_TOKEN'])
        contract.run(['git', '-c', 'credential.https://github.com.helper=', '-c',
                      'credential.https://github.com.helper=!gh auth git-credential',
                      'clone', '--branch', 'main', '--single-branch',
                      'https://github.com/mayflies-app/homebrew-tap.git', tap], env=env)
        contract.run(['git', '-C', tap, 'config', 'credential.https://github.com.helper', ''])
        contract.run(['git', '-C', tap, 'config', '--add', 'credential.https://github.com.helper', '!gh auth git-credential'])
        candidate = root / '.build/promotion.rb'
        candidate.write_text(contract.cask_text(config, version, proof['artifact']['sha256']))
        previous = os.environ.get('GH_TOKEN')
        os.environ['GH_TOKEN'] = os.environ['HOMEBREW_TAP_TOKEN']
        try:
            tap_update.remote_update(tap, config, candidate, version, source, 'main', 'mayflies-app/homebrew-tap')
        finally:
            if previous is None:
                os.environ.pop('GH_TOKEN', None)
            else:
                os.environ['GH_TOKEN'] = previous


def main(argv=None, root=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version')
    parser.add_argument('--build', default='1')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true')
    mode.add_argument('--execute', action='store_true')
    parser.add_argument('--publish', action='store_true', help='Publish and update the cask after final verification')
    args = parser.parse_args(argv)
    root = Path(root).resolve() if root else Path(__file__).resolve().parents[2]
    config = contract.load_config(root / 'macos-app.json')
    version = contract.validate_version(args.version or (root / config.get('versionFile', 'VERSION')).read_text().strip())
    contract.version_order(version)
    build = contract.validate_build(args.build)
    result = plan(root, config, version, build, args.publish)
    if args.execute:
        execute(root, config, version, build, args.publish)
        result.update(mode='executed', executed=True)
    print(json.dumps(result, indent=2))
    return result
