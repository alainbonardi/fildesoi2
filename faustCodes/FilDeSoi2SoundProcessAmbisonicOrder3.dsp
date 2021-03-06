//--------------------------------------------------------------------------------------//
//-------------------------------FilDeSoi2SoundProcess.dsp------------------------------//
//
//-------------------------BY ALAIN BONARDI - 2017 - 2021-------------------------------//
//--------------------------------------------------------------------------------------//

//CHANGES
//Doppler pitchshifters remains at 4 overlapped blocks
//Maximum delay size in samples is now 1048576 (and no longer 2097152)
//that is more than 21 seconds at 48 KHz

import("stdfaust.lib");

//
//--------------------------------------------------------------------------------------//
//FEEDBACK REINJECTION MATRIX N x N
//--------------------------------------------------------------------------------------//
fd_toggle(c, in) = checkbox("h:Lines/h:Reinjection_Matrix/v:Del%2c-->/r%3in");
fd_Mixer(N,out) 	= par(in, N, *(fd_toggle(in, in+out*N)) ) :> _ ;
fdMatrix(N) 	= par(in, N, _) <: par(out, N, fd_Mixer(N, out));

//--------------------------------------------------------------------------------------//
//SPATIALIZATION MATRIX N x M
//--------------------------------------------------------------------------------------//
sp_toggle(c, in) = checkbox("h:Lines/h:SpatializationMatrix/v:Sig%2c-->/sp%3in") : spatSmoothLine;
sp_Mixer(N,out) 	= par(in, N, *(sp_toggle(in, in+out*N)) ) :> _ ;
spMatrix(N,M) 	= par(in, N, _) <: par(out, M, sp_Mixer(N, out));

//--------------------------------------------------------------------------------------//
tablesize = 1 << 16;
sinustable = os.sinwaveform(tablesize);
millisec = ma.SR / 1000.0;

//--------------------------------------------------------------------------------------//
//CONTROL PARAMETERS FOR RANDOM ENV PROCESSES
//--------------------------------------------------------------------------------------//

renv_rarefaction = hslider("h:RandomEnv/renv_short", 0.5, 0, 1, 0.01);
renv_freq = nentry("h:RandomEnv/renv_freq", 10, 0.01, 100, 0.01);
renv_trim = hslider("h:RandomEnv/renv_trim", 0, -127, 18, 0.01) : smoothLine : dbcontrol;

//--------------------------------------------------------------------------------------//
//CONTROL PARAMETERS FOR DELHARMO PROCESSES
//--------------------------------------------------------------------------------------//

//Size of the harmonizer window for Doppler effect//
hWin = hslider("h:Global_Parameters/hWin", 64, 1, 127, 0.01) : pdLineDrive4096;

//Duration of smoothing//
smoothDuration = hslider("h:Global_Parameters/smoothDuration", 20, 10, 5000, 1)/1000;

//Delay line parameters//

d(ind) = int(hslider("h:Lines/v:Del_Durations/d%2ind", (100*(ind+1)), 0, 21000, 1)*millisec*hslider("h:Global_Parameters/dStretch [7]", 1, 0.01, 10, 0.01));
fd(ind) = hslider("h:Lines/v:Del_Feedbacks/fd%2ind", 0, 0, 0.99, 0.01):smoothLine;

//Dispatching between harmonizer (1) and simple delay (0)//
xvd(ind) = hslider("h:Lines/v:EffeX_vs_Del/xvd%2ind", 1, 0, 1, 0.01);

//Transposition in midicents//
tr(ind) = hslider("h:Lines/v:Harmo_Transpositions/tr%2ind", 0, -2400, 2400, 1)*hslider("h:Global_Parameters/hStretch [7]", 1, -10, 10, 0.01);

//Input gains//
//from 0 to 1//
inp(ind) = hslider("h:Lines/v:Line_input/inp%2ind [5]", 1, 0, 1, 0.01):smoothLine;

//OUTPUT GAINS//
//from 0 to 4 since harmonizers can fade the output signal//
out(ind) = hslider("h:Lines/v:Line_output/out%2ind [6]", 1, 0, 1, 0.01):smoothLine;


//--------------------------------------------------------------------------------------//
//CONTROL PARAMETERS GAINS
//--------------------------------------------------------------------------------------//
generalGain = hslider("h:Global_Parameters/generalGain [7]", 0, -127, 18, 0.01) : smoothLine : dbcontrol;
guitarGain = hslider("h:Global_Parameters/guitarGain [7]", -34, -127, 18, 0.01) : smoothLine : dbcontrol;
delharmoGain = hslider("h:Global_Parameters/delharmoGain [7]", 0, -127, 18, 0.01) : smoothLine : dbcontrol;

//--------------------------------------------------------------------------------------//
//CONTROL PARAMETERS FOR ENCODERS
//--------------------------------------------------------------------------------------//
rotfreq(ind) = hslider("h:Encoders/rotfreq%ind", 0.1, -10, 10, 0.01);
rotphase(ind) = hslider("h:Encoders/rotphase%ind", 0, 0, 1, 0.01);


//--------------------------------------------------------------------------------------//
//DEFINITION OF 2 SMOOTHING FUNCTIONS FOR CONTROLLERS
//--------------------------------------------------------------------------------------//
smoothLine = si.smooth(ba.tau2pole(smoothDuration));
spatSmoothLine = si.smooth(ba.tau2pole(0.2));//200 msec interpolation for spatialization matrix//


//--------------------------------------------------------------------------------------//
// GENERATORS
//--------------------------------------------------------------------------------------//
//--------------------------------------------------------------------------------------//
// PHASOR THAT ACCEPTS BOTH NEGATIVE AND POSITIVE FREQUENCES
//--------------------------------------------------------------------------------------//
pdPhasor(f) = os.phasor(1, f);

//--------------------------------------------------------------------------------------//
// SINUS ENVELOPE
//--------------------------------------------------------------------------------------//
sinusEnvelop(phase) = s1 + d * (s2 - s1)
	with {
			zeroToOnePhase = phase : ma.decimal;
			myIndex = zeroToOnePhase * float(tablesize);
			i1 = int(myIndex);
			d = ma.decimal(myIndex);
			i2 = (i1+1) % int(tablesize);
			s1 = rdtable(tablesize, sinustable, i1);
			s2 = rdtable(tablesize, sinustable, i2);

};

//-------------------------------------------------------------------------
// Implementation of Max/MSP line~. Generate signal ramp or envelope 
// 
// USAGE : line(value, time)
// 	value : the desired output value
//	time  : the interpolation time to reach this value (in milliseconds)
//
// NOTE : the interpolation process is restarted every time the desired
// output value changes. The interpolation time is sampled only then.
//
// comes from the maxmsp.lib - no longer standard library
//
//-------------------------------------------------------------------------
line (value, time) = state~(_,_):!,_ 
	with {
		state (t, c) = nt, ba.if (nt <= 0, value, c+(value - c) / nt)
		with {
			nt = ba.if( value != value', samples, t-1);
			samples = time*ma.SR/1000.0;
		};
	};

//--------------------------------------------------------------------------------------//
//DEFINITION OF A PUREDATA LIKE LINEDRIVE OBJECT
//--------------------------------------------------------------------------------------//
pdLineDrive(vol, ti, r, f, b, t) = transitionLineDrive
	with {
			//vol = current volume in Midi (0-127)
			//ti = current time of evolution (in msec)
			//r is the range, usually Midi range (127)
			//f is the factor, usually 2
			//b is the basis, usually 1.07177
			//t is the ramp time usually 30 ms

			pre_val = ba.if (vol < r, vol, r);
			val = ba.if (pre_val < 1, 0, f*pow(b, (pre_val - r)));
			pre_ti = ba.if (ti < 1.46, t, ti);
			transitionLineDrive = line(val, pre_ti);
		};
pdLineDrive4096 = (_, 30, 127, 4096, 1.07177, 30) : pdLineDrive;

//--------------------------------------------------------------------------------------//
//CLIP FUNCTION BETWEEN -1 AND 1
//--------------------------------------------------------------------------------------//
clip(x) = (-1) * infTest + 1 * supTest + x * rangeTest
	with {
			infTest = (x < -1);
			supTest = (x > 1);
			rangeTest = (1 - infTest) * (1 - supTest);
};

//--------------------------------------------------------------------------------------//
// CONVERSION DB=>LINEAR
//--------------------------------------------------------------------------------------//
dbcontrol = _ <: ((_ > -127.0), ba.db2linear) : *;

//--------------------------------------------------------------------------------------//
//DOUBLE OVERLAPPED DELAY
//--------------------------------------------------------------------------------------//
//
//nsamp is an integer number corresponding to the number of samples of delay
//freq is the frequency of envelopping for the overlapping between the 2 delay lines
//--------------------------------------------------------------------------------------//

maxSampSize = 1048576;
delay21s(nsamp) = de.delay(maxSampSize, nsamp);

overlappedDoubleDelay21s(nsamp, freq) = doubleDelay
	with {
			env1 = freq : pdPhasor : sinusEnvelop : *(0.5) : +(0.5);
			env1c = 1 - env1;
			th1 = (env1 > 0.001) * (env1@1 <= 0.001); //env1 threshold crossing
			th2 = (env1c > 0.001) * (env1c@1 <= 0.001); //env1c threshold crossing
			nsamp1 = nsamp : ba.sAndH(th1);
			nsamp2 = nsamp : ba.sAndH(th2);
			doubleDelay =	_ <: (delay21s(nsamp1), delay21s(nsamp2)) : (*(env1), *(env1c)) : + ;
		};

doubleDelay21s(nsamp) = overlappedDoubleDelay21s(nsamp, 30);

//other possibility with de.sdelay
//doubleDelay21s(nsamp) = de.sdelay(maxSampSize, 1024, nsamp);

//--------------------------------------------------------------------------------------//
//DEFINITION OF AN ELEMENTARY TRANSPOSITION BLOCK
//--------------------------------------------------------------------------------------//
transpoBlock(moduleOffset, midicents, win) = dopplerDelay
			with {
					freq = midicents : +(6000) : *(0.01) : ba.midikey2hz : -(261.625977) : *(-3.8224) /(float(win));
					//shifted phasor//
					adjustedPhasor = freq : pdPhasor : +(moduleOffset) : ma.decimal;
					//threshold to input new control values//
					th_trigger = (adjustedPhasor > 0.001) * (adjustedPhasor@1 <= 0.001);
					trig_win = win : ba.sAndH(th_trigger);
					delayInSamples = adjustedPhasor : *(trig_win) : *(millisec);
					variableDelay = de.fdelay(262144, delayInSamples);
					cosinusEnvelop = adjustedPhasor : *(0.5) : sinusEnvelop;
					dopplerDelay = (variableDelay, cosinusEnvelop) : * ;
				};


overlapped4Harmo(tra, win) = _ <: par(i, 4, transpoBlock(i/4, tra, win)) :> _ ;

overlapped4HarmoDryWet(tra, alpha, win) = _ <: (*(alpha), *(1-alpha)) : (overlapped4Harmo(tra, win), _) :> _ ;


//--------------------------------------------------------------------------------------//
//INPUT DISPATCHING
//--------------------------------------------------------------------------------------//
//
//starting with 2n values sigA1, sigA2, ... sigAn, sigB1, sigB2, ... sigBn
//the result is the vector sigA1, sigB1, sigA2, sigB2, ..., sigAn, sigBn
//--------------------------------------------------------------------------------------//
inputSort(n) = si.bus(2*n) <: par(i, n, (ba.selector(i, 2*n), ba.selector(i+n, 2*n)));

//--------------------------------------------------------------------------------------//
//RANDOM ENV SHORTENING FUNCTIONS
//--------------------------------------------------------------------------------------//
//
shorteningEnv(f, s) = ((ramp : *(0.5) : sinusEnvelop), _) : *(factor)
	with {
			randTest = (_, (s : *(2) : -(1))) : >;
			ramp = pdPhasor(f);
			th = (ramp > 0.001) * (ramp@1 <= 0.001);
			factor = randTest : ba.sAndH(th);
	};

mTShorteningEnv(n, f, s) = no.multinoise(n) : par(i, n, shorteningEnv(f, s));

mTShortening(n, f, s) = par(i, n, _), mTShorteningEnv(n, f, s) : inputSort(n) : par(i, n, *);
mTShortening6(f, s, t) = _ : *(t) <: (_, _, _, _, _, _) : mTShortening(6, f, s);

//--------------------------------------------------------------------------------------//
//BLOCK DEFINITIONS
//--------------------------------------------------------------------------------------//
//delay block//
DelBlock(n) = par(i, n, (+ : doubleDelay21s(d(i))));

//harmonizer block//
HarmoBlock(n) = par(i, n, (clip : overlapped4HarmoDryWet(tr(i), xvd(i), hWin)));

//delay and harmonizer block//
DelHarmoBlock(n) = DelBlock(n) : HarmoBlock(n);

//feedback block//
fdBlock(n) = par(i, n, *(fd(i) : *(1 - xvd(i) * 0.75)));

//feedback and dispatching block//
fdToMatrixBlock(n) = fdBlock(n) : fdMatrix(n);

//n inlets with n gain controls//
inputBlock(n) = par(i, n, *(inp(i)));

//output gain block with n gain controls//
outputBlock(n) = par(i, n, *(out(i)));

//general gain over all outputs//
generalGainBlock(n) = par(i, n, *(generalGain));


//--------------------------------------------------------------------------------------//
//MTAP PROCESSES
//DELAY COMBINED WITH OTHER EFFECT DEFINITION
//--------------------------------------------------------------------------------------//
//
//mTDel(n) = n delay lines with reinjection
//mTDelHarmo(n) = n {delay lines + harmonizers} with reinjection
//with 2n delay lines and reinjection
//
//each of them with two possibilities: 
//-either autoReinj which means a delay line can reinject sound only into itself (A)
//-or multReinj which means a delay line can reinject sound into any delay line (M)
//--------------------------------------------------------------------------------------//

mTDelHarmoM(n) = (inputSort(n) : DelHarmoBlock(n)) ~ (fdToMatrixBlock(n));

//--------------------------------------------------------------------------------------//
//SAME PROCESSES WITH INPUT AND OUTPUT GAINS (G)
//--------------------------------------------------------------------------------------//
//
//mTDelHarmoMG : 1 inlet to n {delay lines + harmonizers} with multiple reinjection
//--------------------------------------------------------------------------------------//

//--------------------------------------------------------------------------------------//
//DELAYS WITH HARMONIZERS
mTDelHarmoMG(n) = _ <: (inputBlock(n) : mTDelHarmoM(n) : outputBlock(n));


//--------------------------------------------------------------------------------------//
//AMBISONICS SPATIALIZER
//--------------------------------------------------------------------------------------//
//ajout d'une phase//
pdPhasorWithPhase(f, p) = (1-vn) * x + vn * p
with {
		vn = (f == 0);
		x = (pdPhasor(f), p, 1) : (+, _) : fmod;
};
phasedAngle(f, p) = pdPhasorWithPhase(f, p) * 2 * ma.PI;

myEncoder(sig, angle) = ho.encoder(3, sig, angle);
phasedEncoder(f, p) = (_, phasedAngle(f, p)) : myEncoder;
phasedEncoderBlock = par(i, 4, phasedEncoder(rotfreq(i), rotphase(i))) :> (_, _, _, _, _, _, _);



//--------------------------------------------------------------------------------------//
//PROCESS
//--------------------------------------------------------------------------------------//
//processes on sound guitar
//level 1: harmo and del, random env, direct guitar//
guitar_process = _ <: (*(delharmoGain), *(guitarGain), _) : (mTDelHarmoMG(16), _, mTShortening6(renv_freq, renv_rarefaction, renv_trim));

//level 2: dispatching to spat process (ambisonic model: 7 harmonics and 4 encoders)
toSpat_process = (spMatrix(17, 11), _, _, _, _, _, _);

//level 3: ambisonics spat itself
spat_process = (_, _, _, _, _, _, _, phasedEncoderBlock) : inputSort(7) : (+, +, +, +, +, +, +);

process =  guitar_process : toSpat_process : (spat_process, _, _, _, _,  _, _ ) : (_, inputSort(6)) : (_, +, +, +, +, +, +) : generalGainBlock(7);



