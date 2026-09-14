"""CPU Silero ONNX inference without loading PyTorch on the Mac."""
import numpy as np


class NumpySilero:
    def __init__(self, model_path):
        import onnxruntime as ort
        options=ort.SessionOptions()
        options.intra_op_num_threads=1
        options.inter_op_num_threads=1
        self.session=ort.InferenceSession(str(model_path),sess_options=options,providers=['CPUExecutionProvider'])
        self.legacy={item.name for item in self.session.get_inputs()} == {'x','h','c'}
        self.reset_states()

    def reset_states(self):
        self.h=np.zeros((2,1,64),np.float32)
        self.c=np.zeros((2,1,64),np.float32)
        self.state=np.zeros((2,1,128),np.float32)
        self.context=np.zeros((1,64),np.float32)

    def __call__(self, audio, sample_rate):
        frame=np.asarray(audio,dtype=np.float32).reshape(1,-1)
        if sample_rate!=16000 or frame.shape!=(1,512) or not np.isfinite(frame).all():
            raise ValueError('Silero requires 512 finite samples at 16000 Hz')
        if self.legacy:
            output,self.h,self.c=self.session.run(None,{'x':frame,'h':self.h,'c':self.c})
        else:
            combined=np.concatenate((self.context,frame),axis=1)
            output,self.state=self.session.run(None,{'input':combined,'state':self.state,'sr':np.array(16000,np.int64)})
            self.context=combined[:,-64:].copy()
        return float(output.reshape(-1)[0])
