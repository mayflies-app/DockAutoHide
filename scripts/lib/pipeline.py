"""Plan a release locally; execution is explicit and restricted to manual CI."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
import shutil

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
                      '--output-format', 'json']},
            {'step': 'wait-for-notarization', 'architecture': arch,
             'argv': ['xcrun', 'notarytool', 'wait', '$SUBMISSION_ID', '--key', '$TEMP_AUTH_KEY_P8',
                      '--key-id', '$APPLE_NOTARIZATION_KEY_ID', '--issuer', '$APPLE_NOTARIZATION_ISSUER_ID',
                      '--timeout', '30m', '--output-format', 'json']},
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


def execution_source(root, config):
    contract.require_ci_remote(True, True)
    source = os.environ.get('GITHUB_SHA', '')
    if not contract.COMMIT.fullmatch(source):
        raise ValueError('Execution requires the full GITHUB_SHA')
    if os.environ.get('GITHUB_REPOSITORY', config['repository']) != config['repository']:
        raise ValueError('Workflow repository differs from app configuration')
    state = contract.source_state(root, source)
    if state['dirty']:
        raise ValueError('Release execution requires a clean checkout')
    return source


def preflight(root, config, version, build, publish, deferred=False):
    with contract.release_stage('preflight'):
        source = execution_source(root, config)
        if publish and release.github_json('repos/' + config['repository']).get('visibility') != 'public':
            raise ValueError('Public publication requires a public release repository')
        if not deferred:
            with contract.release_stage('toolchain'):
                ci_prepare.verify_toolchain()
        flags = ['preflight', '--config', str(root / 'macos-app.json'), '--version', version,
                 '--build', build, '--source-commit', source, '--sign-mode', 'developer-id',
                 '--request-notarization', '--ci', '--allow-remote', '--online']
        if publish:
            flags += ['--request-publish', '--request-tap']
        return release.main(flags, check_credentials=not deferred)


def publish_release(root, config, version, source):
    with contract.release_stage('publish'):
        proof = release.publish(config, version, source, root / 'dist/release')
    print(f"[release] Public release verified: https://github.com/{config['repository']}/releases/tag/v{version}", file=sys.stderr, flush=True)
    print('[release] Subsequent tap failures do not roll back this release; repair the cask without rebuilding or replacing published assets.', file=sys.stderr, flush=True)
    return proof


def promote_cask(root, config, version, source, proof):
    contract.require_ci_remote(True, True, token_name='HOMEBREW_TAP_TOKEN')
    tap = root / '.build/release-tap'
    if tap.exists():
        raise ValueError('Tap execution needs a fresh checkout')
    tap.parent.mkdir(parents=True, exist_ok=True)
    # Supply the tap token through Git's credential helper environment, never the URL.
    env = dict(os.environ, GH_TOKEN=os.environ['HOMEBREW_TAP_TOKEN'])
    with contract.release_stage('tap-clone'):
        contract.run(['git', '-c', 'credential.https://github.com.helper=', '-c',
                      'credential.https://github.com.helper=!gh auth git-credential',
                      'clone', '--branch', 'main', '--single-branch',
                      'https://github.com/mayflies-app/homebrew-tap.git', tap], env=env, capture_output=True, text=True)
        contract.run(['git', '-C', tap, 'config', 'credential.https://github.com.helper', ''])
        contract.run(['git', '-C', tap, 'config', '--add', 'credential.https://github.com.helper', '!gh auth git-credential'])
    candidate = root / '.build/promotion.rb'
    candidate.write_text(contract.cask_text(config, version, proof['artifact']['sha256']))
    previous = os.environ.get('GH_TOKEN')
    os.environ['GH_TOKEN'] = os.environ['HOMEBREW_TAP_TOKEN']
    try:
        with contract.release_stage('tap-update'):
            tap_update.remote_update(tap, config, candidate, version, source, 'main', 'mayflies-app/homebrew-tap')
    finally:
        if previous is None:
            os.environ.pop('GH_TOKEN', None)
        else:
            os.environ['GH_TOKEN'] = previous



def restore_notary_state(root, config):
    """Read only this run's latest prior checkpoint artifact; never use another run."""
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '1')
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    if not attempt.isdigit() or int(attempt) < 1 or not run_id.isdigit():
        raise ValueError('Notary job requires its workflow run ID and attempt')
    if int(attempt) == 1:
        return
    run = release.github_json(f"repos/{config['repository']}/actions/runs/{run_id}")
    if run.get('head_sha') != os.environ.get('GITHUB_SHA') or run.get('event') != 'workflow_dispatch':
        raise ValueError('Notary checkpoint run/source mismatch')
    pages = release.github_json(f"repos/{config['repository']}/actions/runs/{run_id}/artifacts?per_page=100", paginate=True)
    candidates = []
    for page in pages:
        for artifact in page['artifacts']:
            name = artifact.get('name', '')
            prefix = 'release-notary-state-'
            if name.startswith(prefix) and name[len(prefix):].isdigit() and int(name[len(prefix):]) < int(attempt):
                candidates.append((int(name[len(prefix):]), artifact))
    if not candidates:
        jobs = release.github_json(f"repos/{config['repository']}/actions/runs/{run_id}/jobs?filter=all&per_page=100", paginate=True)
        attempted = any(job.get('name') == 'notarize' and job.get('run_attempt', 0) < int(attempt)
                        and any(step.get('name') == 'Resume or submit notarization and verify final bytes'
                                and step.get('conclusion') not in (None, 'skipped') for step in job.get('steps', []))
                        for page in jobs for job in page['jobs'])
        if attempted:
            raise ValueError('Prior notary execution has no retained checkpoint; inspect Apple submission history before a new workflow run')
        return
    artifact = max(candidates, key=lambda item: item[0])[1]
    if artifact.get('expired'):
        raise ValueError('Prior notary state expired; inspect the retained submission ID before retrying')
    output = root / 'dist/release/universal'
    # Version overrides are taken from the already verified package filename.
    dmgs = list(output.glob('*.dmg'))
    if len(dmgs) != 1:
        raise ValueError('Notary state requires exactly one signed DMG')
    receipt = dmgs[0].with_suffix('.notary.json')
    allowed = {receipt.name, receipt.with_suffix('.submission.json').name, receipt.with_suffix('.log.json').name}
    with tempfile.TemporaryDirectory(prefix='notary-checkpoint-') as temporary:
        contract.run(['gh', 'run', 'download', run_id, '--repo', config['repository'], '--name', artifact['name'], '--dir', temporary], capture_output=True)
        files = list(Path(temporary).rglob('*'))
        if any(not path.is_file() or path.is_symlink() or path.name not in allowed or path.parent != Path(temporary) for path in files):
            raise ValueError('Notary checkpoint artifact contains unexpected files')
        if receipt.with_suffix('.submission.json').name not in {path.name for path in files}:
            raise ValueError('Prior notary artifact has no submission checkpoint; inspect Apple submission history before a new workflow run')
        for path in files:
            if (output / path.name).exists():
                raise ValueError('Notary checkpoint would replace existing local state')
            shutil.copyfile(path, output / path.name)
    print(f"[release] Restored notary checkpoint from {artifact['name']}", file=sys.stderr, flush=True)


def execute(root, config, version, build, publish, stage=None):
    if stage == 'preflight':
        return preflight(root, config, version, build, publish, deferred=True)
    if stage:
        source = execution_source(root, config)
        if stage in ('publish', 'cask') and not publish:
            raise ValueError(f'{stage} requires explicit --publish')
        with contract.release_stage(stage):
            if stage == 'package':
                ci_prepare.verify_toolchain()
                ci_prepare.prepare(root / 'macos-app.json', version, build, 'universal',
                                   root / 'dist/release/universal', signed=True, notarized=False)
            elif stage == 'notarize':
                ci_prepare.verify_toolchain()
                restore_notary_state(root, config)
                ci_prepare.notarize_existing(root / 'macos-app.json', version, build, source)
            elif stage == 'publish':
                if release.github_json('repos/' + config['repository']).get('visibility') != 'public':
                    raise ValueError('Public publication requires a public release repository')
                publish_release(root, config, version, source)
            elif stage == 'cask':
                proof = release.verify_public_release(config, version, source)
                promote_cask(root, config, version, source, proof)
        return
    # The complete CLI run uses the same owners as the independently scheduled jobs.
    checked = preflight(root, config, version, build, publish)
    source = os.environ['GITHUB_SHA']
    if not checked['reuse']:
        with contract.release_stage('prepare'):
            ci_prepare.prepare(root / 'macos-app.json', version, build, 'universal',
                               root / 'dist/release/universal', signed=True, notarized=True)
            contract.collect(config, root / 'dist/release', version, source, promotion=True)
    if publish:
        proof = publish_release(root, config, version, source)
        promote_cask(root, config, version, source, proof)


def main(argv=None, root=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version')
    parser.add_argument('--build', default='1')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true')
    mode.add_argument('--execute', action='store_true')
    parser.add_argument('--stage', choices=('preflight', 'package', 'notarize', 'publish', 'cask'))
    parser.add_argument('--publish', action='store_true', help='Publish and update the cask after final verification')
    args = parser.parse_args(argv)
    if args.stage and not args.execute:
        parser.error('--stage requires --execute')
    root = Path(root).resolve() if root else Path(__file__).resolve().parents[2]
    config = contract.load_config(root / 'macos-app.json')
    version = contract.validate_version(args.version or (root / config.get('versionFile', 'VERSION')).read_text().strip())
    contract.version_order(version)
    build = contract.validate_build(args.build)
    result = plan(root, config, version, build, args.publish)
    if args.execute:
        execute(root, config, version, build, args.publish, args.stage)
        result.update(mode='executed', executed=True)
        if args.stage:
            result = {'mode': 'executed', 'executed': True, 'stage': args.stage,
                      'version': version, 'build': build, 'publish': args.publish}
    print(json.dumps(result, indent=2))
    return result
