import datetime, hashlib, json, subprocess, sys
from pathlib import Path
root = Path.cwd()
work = root / '.dev/shibuya-timing'
setup = json.loads((work / 'executables.json').read_text())
phase = sys.argv[1] if len(sys.argv) > 1 else 'paired'
run_label = sys.argv[2] if len(sys.argv) > 2 else 'shibuya-2026-10-10'
index_path = work / (f'{phase}-index.json' if run_label == 'shibuya-2026-10-10' else f'{run_label}-{phase}-index.json')
index = []
for scenario in ['core', 'pgmq', 'kiroku']:
    for pair in range(1, 2 if phase == 'calibration' else 6):
        arms = ['baseline', 'candidate'] if pair % 2 else ['candidate', 'baseline']
        for arm in arms:
            out = root / 'runs' / f'{run_label}-{phase}' / scenario / f'pair-{pair}' / arm
            out.mkdir(parents=True, exist_ok=True)
            spec = work / (f'{scenario}-calibration.json' if phase == 'calibration' else f'{scenario}.json')
            cmd = [setup[arm], 'run', '--spec', str(spec), '--out', str(out), '--cohort-identity', str(work / 'baseline-identity.json')] if arm == 'baseline' else [setup[arm], 'run', str(spec), str(out), '--plan-json', str(work / 'current-plan.json')]
            cmd += ['+RTS', '-N4', '-T', '-RTS']
            activity = subprocess.check_output(['ps', '-axo', 'pid,pcpu,etime,comm'], text=True)
            busy = [line for line in activity.splitlines()[1:] if float(line.split()[1]) > 20]
            (out / 'ambient-cpu.txt').write_text('\n'.join(busy) + '\n')
            print(datetime.datetime.now(datetime.timezone.utc).isoformat(), scenario, pair, arm, 'START', flush=True)
            completed = subprocess.run(cmd, text=True, capture_output=True, timeout=240)
            (out / 'driver.stdout.txt').write_text(completed.stdout)
            (out / 'driver.stderr.txt').write_text(completed.stderr)
            runs = list(out.glob('*/run-result.json'))
            if len(runs) != 1:
                print(completed.stdout, completed.stderr, flush=True)
                raise RuntimeError(f'{scenario}/{arm}: no unique completed run, exit={completed.returncode}')
            directory = runs[0].parent
            manifest = json.loads((directory / 'manifest.json').read_text())
            for entry in manifest['files']:
                data = (directory / entry['path']).read_bytes()
                assert len(data) == entry['bytes'] and 'sha256:' + hashlib.sha256(data).hexdigest() == entry['sha256'], entry['path']
            result = json.loads(runs[0].read_text())
            row = {'scenario': scenario, 'pair': pair, 'arm': arm, 'directory': str(directory.relative_to(root)), 'exitCode': completed.returncode, 'command': cmd, 'outcome': result.get('outcome')}
            index.append(row)
            index_path.write_text(json.dumps(index, indent=2) + '\n')
            print(scenario, pair, arm, 'END', completed.returncode, completed.stdout.strip(), flush=True)
            verify = subprocess.run([setup['baseline'], 'summarize', str(directory), '--verify', '--json'], capture_output=True, text=True)
            (out / 'verified-summary.json').write_text(verify.stdout)
            if verify.returncode or completed.returncode:
                print(completed.stderr, verify.stderr, flush=True)
                raise RuntimeError(f'{scenario}/{arm}: run or summary verification failed')
print('ALL TRIALS COMPLETE', flush=True)
