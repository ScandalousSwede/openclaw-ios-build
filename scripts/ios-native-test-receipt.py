"""Emit scoped native test metadata; never imply signing or delivery success."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

MAX_BYTES = 1024 * 1024
MAX_INT = 9007199254740991


def count(value):
    if value is None:
        return None
    if type(value) is not int or not 0 <= value <= MAX_INT:
        raise ValueError('invalid test count')
    return value


def receipt(summary, *, source_sha, run_id, run_attempt, step_outcome, unavailable_reason=None):
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('invalid source identity')
    if type(run_id) is not int or type(run_attempt) is not int or not 1 <= run_id <= MAX_INT or not 1 <= run_attempt <= MAX_INT:
        raise ValueError('invalid run identity')
    if step_outcome not in {'success', 'failure', 'cancelled', 'skipped'}:
        raise ValueError('invalid step outcome')
    reasons = {None, 'result_bundle_missing', 'summary_command_failed', 'summary_exceeds_budget',
               'summary_command_unavailable', 'summary_invalid_json', 'summary_contract_unrecognized'}
    if unavailable_reason not in reasons: raise ValueError('invalid unavailable reason')
    if summary is None and unavailable_reason is None: unavailable_reason='summary_contract_unrecognized'
    tests = {key: None for key in ('total', 'passed', 'failed', 'skipped', 'expected_failures')}
    result = None
    if summary is not None:
        if not isinstance(summary, dict): raise ValueError('invalid native summary')
        result = summary.get('result')
        if not isinstance(result, str) or result not in {'Passed', 'Failed', 'Skipped', 'Unknown'}:
            raise ValueError('unsupported native result')
        for name, field in [('total','totalTestCount'),('passed','passedTests'),('failed','failedTests'),('skipped','skippedTests'),('expected_failures','expectedFailures')]:
            tests[name] = count(summary.get(field))
        if tests['total'] is not None:
            if any(value is not None and value > tests['total'] for key,value in tests.items() if key != 'total'):
                raise ValueError('inconsistent native counts')
            if tests['passed'] is not None and tests['failed'] is not None and tests['passed'] + tests['failed'] > tests['total']:
                raise ValueError('inconsistent native counts')
        if result == 'Passed' and tests['failed'] not in (None, 0):
            raise ValueError('contradictory native result')
    established = (unavailable_reason is None and step_outcome == 'success' and result == 'Passed'
                   and all(value is not None for value in tests.values())
                   and tests['total'] > 0 and tests['passed'] == tests['total']
                   and tests['failed'] == tests['skipped'] == tests['expected_failures'] == 0)
    return {'schema':'argus.ios-native-test-receipt.v2','source_sha':source_sha,'run_id':run_id,
            'run_attempt':run_attempt,'scope':'focused_ios_reliability_simulator',
            'count_basis':'combined_xcresult',
            'step_outcome':step_outcome,'native_result':result,'tests':tests,
            'native_suites':None,'new_regressions_passed':None,
            'all_selected_tests_passed':established,'unavailable_reason':unavailable_reason,
            'physical_device_evidence':False,'owner_accepted':False}


def collect(path, **identity):
    reason=None;summary=None;digest=None
    if not path.is_dir():
        reason='result_bundle_missing'
    else:
        try:
            command=['xcrun','xcresulttool','get','test-results','summary','--path',str(path),'--compact']
            result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60,check=False)
            if result.returncode:
                reason='summary_command_failed'
            elif len(result.stdout)>MAX_BYTES:
                reason='summary_exceeds_budget'
            else:
                summary=json.loads(result.stdout)
                digest=hashlib.sha256(result.stdout).hexdigest()
        except (OSError,subprocess.TimeoutExpired):
            reason='summary_command_unavailable'
        except (ValueError,UnicodeError):
            reason='summary_invalid_json'
    try:
        value=receipt(summary,unavailable_reason=reason,**identity)
    except ValueError:
        # An unfamiliar output contract cannot silently become zero/passed tests.
        value=receipt(None,unavailable_reason='summary_contract_unrecognized',**identity)
    value['summary_sha256']=digest
    return value


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--result-bundle',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--source-sha',required=True)
    parser.add_argument('--run-id',type=int,required=True)
    parser.add_argument('--run-attempt',type=int,required=True)
    parser.add_argument('--step-outcome',required=True)
    args=parser.parse_args()
    value=collect(args.result_bundle,source_sha=args.source_sha,run_id=args.run_id,
                  run_attempt=args.run_attempt,step_outcome=args.step_outcome)
    # Exclusive output: no overwrite or deletion of prior evidence.
    with args.output.open('x',encoding='utf-8') as target:
        json.dump(value,target,sort_keys=True,indent=2)
        target.write('\n')


if __name__=='__main__':main()
