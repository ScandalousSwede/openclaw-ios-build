import importlib.util,json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('receipt',Path(__file__).with_name('ios-native-test-receipt.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
IDENTITY=dict(source_sha='a'*40,run_id=34090428404,run_attempt=1,step_outcome='success')
class ReceiptTests(unittest.TestCase):
 def test_combined_framework_summary_not_swifttesting_count(self):
  value=module.receipt({'result':'Passed','totalTestCount':439,'passedTests':439,'failedTests':0,'skippedTests':0,'expectedFailures':0},**IDENTITY)
  self.assertEqual(value['tests']['total'],439);self.assertTrue(value['all_selected_tests_passed']);self.assertIsNone(value['native_suites']);self.assertIsNone(value['new_regressions_passed']);self.assertFalse(value['physical_device_evidence'])
 def test_missing_count_stays_unknown_and_no_pass(self):
  value=module.receipt({'result':'Passed','passedTests':435},**IDENTITY)
  self.assertIsNone(value['tests']['total']);self.assertIsNone(value['tests']['failed']);self.assertFalse(value['all_selected_tests_passed'])
 def test_failed_step_does_not_borrow_passed_summary(self):
  value=module.receipt({'result':'Passed','totalTestCount':4,'passedTests':4,'failedTests':0},**{**IDENTITY,'step_outcome':'failure'})
  self.assertFalse(value['all_selected_tests_passed']);self.assertEqual(value['step_outcome'],'failure')
 def test_counter_identity_and_contradiction_rejected(self):
  for count in [True,-1,2**60,'435']:
   with self.assertRaises(ValueError):module.receipt({'result':'Passed','totalTestCount':count},**IDENTITY)
  with self.assertRaises(ValueError):module.receipt({'result':'Passed','failedTests':1},**IDENTITY)
  with self.assertRaises(ValueError):module.receipt(None,**{**IDENTITY,'source_sha':'bad'})
 def test_missing_bundle_receipt_preserves_failure_without_fake_zero(self):
  with tempfile.TemporaryDirectory() as temp:
   value=module.collect(Path(temp)/'missing',**{**IDENTITY,'step_outcome':'failure'})
  self.assertEqual(value['unavailable_reason'],'result_bundle_missing');self.assertTrue(all(v is None for v in value['tests'].values()))
 def test_only_metadata_leaves_parser_and_unknown_schema_is_explicit(self):
  class Result: returncode=0;stdout=json.dumps({'result':'Passed','totalTestCount':1,'passedTests':1,'failedTests':0,'skippedTests':0,'expectedFailures':0,'testFailures':[{'private':'UNEXPECTED_BODY'}]}).encode()
  with tempfile.TemporaryDirectory() as temp,patch.object(module.subprocess,'run',return_value=Result()):value=module.collect(Path(temp),**IDENTITY)
  self.assertNotIn('UNEXPECTED_BODY',json.dumps(value));self.assertTrue(value['all_selected_tests_passed'])
  Result.stdout=b'{"result":"NewOutputVersion"}'
  with tempfile.TemporaryDirectory() as temp,patch.object(module.subprocess,'run',return_value=Result()):value=module.collect(Path(temp),**IDENTITY)
  self.assertEqual(value['unavailable_reason'],'summary_contract_unrecognized');self.assertFalse(value['all_selected_tests_passed'])
 def test_skipped_expected_failure_or_incomplete_counts_are_not_all_passed(self):
  baseline={'result':'Passed','totalTestCount':4,'passedTests':4,'failedTests':0,'skippedTests':0,'expectedFailures':0}
  for key,value in [('skippedTests',1),('expectedFailures',1),('expectedFailures',None),('passedTests',3)]:
   result=module.receipt({**baseline,key:value},**IDENTITY)
   self.assertFalse(result['all_selected_tests_passed'])
 def test_non_string_result_is_controlled_unknown_and_reason_prevents_pass(self):
  for result in [{},[]]:
   with self.assertRaises(ValueError):module.receipt({'result':result},**IDENTITY)
   class Command: returncode=0;stdout=json.dumps({'result':result}).encode()
   with tempfile.TemporaryDirectory() as temp,patch.object(module.subprocess,'run',return_value=Command()):
    value=module.collect(Path(temp),**IDENTITY)
   self.assertEqual(value['unavailable_reason'],'summary_contract_unrecognized')
  summary={'result':'Passed','totalTestCount':1,'passedTests':1,'failedTests':0,'skippedTests':0,'expectedFailures':0}
  value=module.receipt(summary,unavailable_reason='summary_command_failed',**IDENTITY)
  self.assertFalse(value['all_selected_tests_passed'])
 def test_cli_missing_bundle_writes_bound_receipt_and_refuses_overwrite(self):
  import subprocess,sys
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);target=root/'receipt.json'
   command=[sys.executable,str(Path(__file__).with_name('ios-native-test-receipt.py')),'--result-bundle',str(root/'missing'),'--output',str(target),'--source-sha','a'*40,'--run-id','34090428404','--run-attempt','2','--step-outcome','failure']
   first=subprocess.run(command,capture_output=True,check=False)
   self.assertEqual(first.returncode,0)
   data=target.read_bytes();value=json.loads(data)
   self.assertEqual(value['run_attempt'],2);self.assertEqual(value['schema'],'argus.ios-native-test-receipt.v2')
   self.assertFalse(value['all_selected_tests_passed']);self.assertIsNone(value['tests']['total'])
   second=subprocess.run(command,capture_output=True,check=False)
   self.assertNotEqual(second.returncode,0);self.assertEqual(target.read_bytes(),data)
 def test_failed_attachment_export_does_not_prevent_independent_receipt_staging(self):
  import os,shutil,subprocess,textwrap
  if os.name!='posix' or shutil.which('bash') is None:self.skipTest('POSIX workflow shell required')
  workflow=Path(__file__).resolve().parent.parent/'.github/workflows/ios-build-ipa.yml'
  source=workflow.read_text(encoding='utf-8')
  blocks=source.split('      - name: Stage native receipt with simulator evidence\n')[1:]
  self.assertEqual(len(blocks),2)
  exports=source.split('      - name: Export simulator fixture screenshots\n')[1:]
  for index,block in enumerate(blocks):
   export_step=exports[index].split('      - name:',1)[0]
   export_script=textwrap.dedent(export_step.split('        run: |\n',1)[1])
   step=block.split('      - name:',1)[0]
   self.assertIn('if: always() && !cancelled()',step)
   script=textwrap.dedent(step.split('        run: |\n',1)[1])
   with tempfile.TemporaryDirectory() as temp:
    root=Path(temp);receipt=root/'OpenClaw-native-test-receipt.json'
    original=b'{"unavailable_reason":"summary_command_failed"}';receipt.write_bytes(original)
    (root/'aies-ios-reliability.xcresult').mkdir()
    binary=root/'bin';binary.mkdir();xcrun=binary/'xcrun';xcrun.write_text('#!/bin/sh\nexit 17\n');xcrun.chmod(0o755)
    environment={**os.environ,'RUNNER_TEMP':temp,'PATH':str(binary)+os.pathsep+os.environ['PATH']}
    failed=subprocess.run(['bash','-c',export_script],env=environment,capture_output=True,check=False)
    self.assertEqual(failed.returncode,17)
    staged=subprocess.run(['bash','-c',script],env={**os.environ,'RUNNER_TEMP':temp},capture_output=True,check=False)
    self.assertEqual(staged.returncode,0,staged.stderr)
    self.assertEqual((root/'aies-simulator-fixture-screenshots'/receipt.name).read_bytes(),original)
if __name__=='__main__':unittest.main()
