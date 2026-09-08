from pathlib import Path
import importlib.util,os,unittest,json,base64,subprocess,tempfile,yaml,io
from unittest.mock import patch
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec,x25519
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.exceptions import InvalidTag
ROOT=Path(os.environ.get('ASC_TOKEN_SOURCE_ROOT',Path(__file__).resolve().parent.parent))
spec=importlib.util.spec_from_file_location('asc_token',ROOT/'scripts/ios-asc-read-token.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ReadToken(unittest.TestCase):
 def setUp(self):
  self.signer=ec.generate_private_key(ec.SECP256R1());self.pem=self.signer.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption());self.recipient=x25519.X25519PrivateKey.generate();self.pub=base64.b64encode(self.recipient.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
 def mint(self):return m.mint(self.pem,'00000000-1111-2222-3333-444444444444','ABCD123456','1234567890',self.pub,now=1000)
 def decrypt(self,packet,recipient=None):
  peer=x25519.X25519PublicKey.from_public_bytes(base64.b64decode(packet['ephemeral_public']));secret=(recipient or self.recipient).exchange(peer);key=HKDF(algorithm=hashes.SHA256(),length=32,salt=None,info=m.CONTEXT).derive(secret)
  return AESGCM(key).decrypt(base64.b64decode(packet['nonce']),base64.b64decode(packet['ciphertext']),m.CONTEXT)
 def test_real_encryption_signature_and_exact_get_scope(self):
  packet=self.mint();token=self.decrypt(packet);header,payload,signature=token.split(b'.');body=json.loads(base64.urlsafe_b64decode(payload+b'='*(-len(payload)%4)));raw=base64.urlsafe_b64decode(signature+b'='*(-len(signature)%4));self.signer.public_key().verify(encode_dss_signature(int.from_bytes(raw[:32],'big'),int.from_bytes(raw[32:],'big')),header+b'.'+payload,ec.ECDSA(hashes.SHA256()))
  self.assertEqual(body['exp']-body['iat'],600);self.assertEqual(body['scope'],m.scopes('1234567890'));self.assertTrue(all(x.startswith('GET ') for x in body['scope']));self.assertNotIn(token.decode(),json.dumps(packet));self.assertNotIn('PRIVATE KEY',json.dumps(packet))
 def test_wrong_recipient_cannot_decrypt(self):
  with self.assertRaises(InvalidTag):self.decrypt(self.mint(),x25519.X25519PrivateKey.generate())
 def test_ciphertext_tamper_rejected(self):
  packet=self.mint();b=bytearray(base64.b64decode(packet['ciphertext']));b[-1]^=1;packet['ciphertext']=base64.b64encode(b).decode()
  with self.assertRaises(InvalidTag):self.decrypt(packet)
 def test_fresh_ephemeral_keys_and_nonces(self):
  a,b=self.mint(),self.mint();self.assertNotEqual(a['ephemeral_public'],b['ephemeral_public']);self.assertNotEqual(a['nonce'],b['nonce'])
 def test_invalid_recipient_app_and_signing_curve_fail(self):
  with self.assertRaises(ValueError):m.mint(self.pem,'00000000-1111-2222-3333-444444444444','ABCD123456','1234567890','invalid')
  with self.assertRaises(ValueError):m.scopes('123/../456')
  other=ec.generate_private_key(ec.SECP384R1()).private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())
  with self.assertRaises(ValueError):m.mint(other,'00000000-1111-2222-3333-444444444444','ABCD123456','1234567890',self.pub)
 def test_actual_cli_only_writes_ciphertext_and_generic_status(self):
  with tempfile.TemporaryDirectory() as directory:
   shim=Path(directory)/'shim';shim.mkdir();(shim/'sitecustomize.py').write_text("import urllib.request,io\nclass Opener:\n def open(self,*a,**k):return io.BytesIO(b'{\"data\":[]}')\nurllib.request.build_opener=lambda *a:Opener()\n")
   env={**os.environ,'PYTHONPATH':str(shim),'ASC_PRIVATE_KEY_P8':self.pem.decode(),'ASC_ISSUER_ID':'00000000-1111-2222-3333-444444444444','ASC_KEY_ID':'ABCD123456','APP_STORE_CONNECT_APP_ID':'1234567890','ASC_READ_RECIPIENT_PUBLIC':self.pub,'RUNNER_TEMP':directory}
   r=subprocess.run(['python3',str(ROOT/'scripts/ios-asc-read-token.py')],env=env,capture_output=True,text=True,timeout=10);self.assertEqual(r.returncode,0,r.stderr)
   packet=json.loads((Path(directory)/'asc-read-capability.json').read_text());token=self.decrypt(packet);self.assertNotIn(token.decode(),r.stdout+r.stderr);self.assertNotIn('ABCD123456',r.stdout+r.stderr)
   env['ASC_PRIVATE_KEY_P8']='synthetic-secret-that-must-not-leak';r=subprocess.run(['python3',str(ROOT/'scripts/ios-asc-read-token.py')],env=env,capture_output=True,text=True,timeout=10);self.assertNotEqual(r.returncode,0);self.assertNotIn(env['ASC_PRIVATE_KEY_P8'],r.stdout+r.stderr)
 def test_actual_dispatch_gate_rejects_wrong_actor_ref_sha_and_no_confirmation(self):
  workflow=yaml.load((ROOT/'.github/workflows/ios-build-ipa.yml').read_text(),Loader=yaml.BaseLoader);script=workflow['jobs']['dispatch-gate']['steps'][0]['run'];env={**os.environ,'AIES_DISTRIBUTION':'scoped-read-token','AIES_CONFIRM_INTERNAL_ONLY':'true','AIES_GITHUB_ACTOR':'ScandalousSwede','AIES_GITHUB_TRIGGERING_ACTOR':'ScandalousSwede','AIES_EXPECTED_SHA':'a'*40,'AIES_GITHUB_SHA':'a'*40,'AIES_REF_NAME':'aies/ios-rc1-testflight','AIES_REF_TYPE':'branch'}
  cases=[({},0),({'AIES_GITHUB_ACTOR':'outsider'},1),({'AIES_GITHUB_TRIGGERING_ACTOR':'outsider'},1),({'AIES_EXPECTED_SHA':'b'*40},1),({'AIES_REF_NAME':'unreviewed'},1),({'AIES_CONFIRM_INTERNAL_ONLY':'false'},1),({'AIES_REF_TYPE':'tag'},1)]
  for change,code in cases:
   with self.subTest(change=change):
    r=subprocess.run(['bash','-c',script],env={**env,**change},capture_output=True,text=True,timeout=5);self.assertEqual(r.returncode,code)
 def test_recent_crash_ids_are_app_discovered_and_scoped(self):
  class Opener:
   def open(inner,req,timeout):
    self.assertEqual(req.get_method(),'GET');self.assertIn('/v1/apps/1234567890/',req.full_url);self.assertIn('limit=10',req.full_url)
    return io.BytesIO(json.dumps({'data':[{'type':'betaFeedbackCrashSubmissions','id':'synthetic_crash-123'}]}).encode())
  with patch.object(m,'build_opener',return_value=Opener()):
   packet=m.mint(self.pem,'00000000-1111-2222-3333-444444444444','ABCD123456','1234567890',self.pub,now=1000,discover=m.recent_crash_scopes)
  part=self.decrypt(packet).split(b'.')[1];claims=json.loads(base64.urlsafe_b64decode(part+b'='*(-len(part)%4)));self.assertEqual(claims['scope'][-1],'GET /v1/betaFeedbackCrashSubmissions/synthetic_crash-123/crashLog');self.assertEqual(len(claims['scope']),3)
 def test_crash_index_cannot_inject_a_path_or_unbounded_scope(self):
  for rows in [[{'type':'betaFeedbackCrashSubmissions','id':'../apps'}],[{'type':'other','id':'123'}],[{'type':'betaFeedbackCrashSubmissions','id':str(n)} for n in range(11)]]:
   class Opener:
    def open(self,*args,**kwargs):return io.BytesIO(json.dumps({'data':rows}).encode())
   with self.subTest(rows=rows),patch.object(m,'build_opener',return_value=Opener()),self.assertRaises(ValueError):m.recent_crash_scopes(b'synthetic-token',m.scopes('1234567890')[1])
if __name__=='__main__':unittest.main()
