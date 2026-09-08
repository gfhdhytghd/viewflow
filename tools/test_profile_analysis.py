"""Adversarial evidence joins: never silently choose an ambiguous frame/packet."""
import copy
import unittest
from profile_atlas_timeline import export
from summarize_alpha_profile import summarize
from summarize_gpu_queues import analyze

class EvidenceTests(unittest.TestCase):
    source = ('atlas-clock-exchange t0=100 t1=98 t2=99 t3=104 remote_offset_ns=-3 uncertainty_ns=2 network_round_trip_ns=3\n'
              'atlas-clock-mapping source_ns=100 remote_offset_ns=-3 uncertainty_ns=2 valid_remaining_ns=1000000\n'
              'atlas-source-timing frame=4 encode_start_ns=200 encoded_ns=300 released_ns=310 batch_return_ns=320 capture_to_encode_start_us=0\n')
    receiver = 'atlas-receiver-clock-anchor frequency=1000000000 qpc=100 before_ns=100 after_ns=102\n'
    def test_signed_clock_rounds_toward_zero(self):
        _,r=export(self.source,self.receiver,'')
        self.assertEqual(r['invalid_exchanges'],[])
    def test_bad_clock_rejected(self):
        with self.assertRaises(AssertionError):export(self.source.replace('remote_offset_ns=-3 uncertainty_ns=2 network','remote_offset_ns=-4 uncertainty_ns=2 network'),self.receiver,'')
    def test_duplicate_source_rejected(self):
        trace,r=export(self.source+self.source.splitlines()[-1]+'\n',self.receiver,'')
        self.assertEqual(trace['traceEvents'],[])
        self.assertEqual(r['skipped']['duplicate_source_identity'],2)
    def test_duplicate_native_phase_rejected(self):
        a='atlas-native-timing frame=4 phase=pipe-admission qpc=350 frequency=1000000000\n'
        b='atlas-native-timing frame=4 phase=decoded qpc=400 frequency=1000000000\n'
        trace,r=export(self.source,self.receiver+a+a+b,'')
        self.assertEqual(r['skipped']['duplicate_native_phase'],1)
        self.assertFalse(any(e['name']=='pipe admission to decoded' for e in trace['traceEvents']))
    def test_alpha_missing_and_duplicate_not_joined(self):
        a='alpha-copy-profile frame=4 stage=pinned_to_vector bytes=9 start_ns=0 end_ns=10 cpu_ns=8 clocks_valid=1\n'
        b=a.replace('pinned_to_vector','cabi_to_rust')
        c='alpha-cache-profile frame=4 bytes=9 wall_ns=10 cpu_ns=8 cpu_valid=true hit=true\n'
        self.assertEqual(summarize(a+b+c)['same_frame_total_wall_ms']['n'],1)
        self.assertEqual(summarize(a+a+b+c)['same_frame_total_wall_ms']['n'],0)
        self.assertEqual(summarize(a+c)['same_frame_total_wall_ms']['n'],0)
    def packet(self):
        def e(name,t,p):return dict(name=name,qpc=t,time_ms=t,pid=7,payload=p)
        return [e('Device/Start',0,dict(hDevice='d',hProcessId='7',pDxgAdapter='a')),
                e('Context/Start',0,dict(hDevice='d',hContext='c',NodeOrdinal='0')),
                e('QueuePacket/Start',1,dict(hContext='c',SubmitSequence='2')),
                e('DmaPacket/Start',3,dict(hContext='c',ulQueueSubmitSequence='2',uliSubmissionId='9')),
                e('DmaPacket',7,dict(hContext='c',ulQueueSubmitSequence='2',uliCompletionId='9')),
                e('DmaPacket/Stop',7,dict(hContext='c',ulQueueSubmitSequence='2',bPreempted='False'))]
    def test_queue_and_residence_are_separate(self):
        _,p=analyze(self.packet(),[dict(pid=7,name='native')])
        self.assertEqual((p[0]['cpu_queue_ms'],p[0]['hardware_residence_ms']),(2,4))
    def test_packet_ambiguity_rejected(self):
        for mode in ('preempt','duplicate','identity','owner','order','missing'):
            e=self.packet()
            if mode=='preempt':e[-1]['payload']['bPreempted']='True'
            if mode=='duplicate':e.append(copy.deepcopy(e[3]))
            if mode=='identity':e[-2]['payload']['uliCompletionId']='10'
            if mode=='owner':e[2]['pid']=8
            if mode=='order':e[3]['qpc']=0
            if mode=='missing':e.pop()
            with self.subTest(mode=mode):self.assertEqual(analyze(e,[])[1],[])

if __name__=='__main__':unittest.main()
