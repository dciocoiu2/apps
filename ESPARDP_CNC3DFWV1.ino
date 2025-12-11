#include <Arduino.h>

#if defined(ARDUINO_RASPBERRY_PI_PICO) || defined(ARDUINO_RASPBERRY_PI_PICO_W) || defined(ARDUINO_RASPBERRY_PI_PICO2) || defined(ARDUINO_RASPBERRY_PI_PICO2W)
  #define BOARD_FAM_RPXX
#elif defined(ARDUINO_ARCH_ESP32)
  #define BOARD_FAM_ESP32
#else
  #define BOARD_FAM_UNKNOWN
#endif

#if defined(ARDUINO_RASPBERRY_PI_PICO)
  #define BOARD_NAME "Raspberry Pi Pico (RP2040)"
#elif defined(ARDUINO_RASPBERRY_PI_PICO_W)
  #define BOARD_NAME "Raspberry Pi Pico W (RP2040)"
#elif defined(ARDUINO_RASPBERRY_PI_PICO2)
  #define BOARD_NAME "Raspberry Pi Pico 2 (RP2350)"
#elif defined(ARDUINO_RASPBERRY_PI_PICO2W)
  #define BOARD_NAME "Raspberry Pi Pico 2W (RP2350)"
#elif defined(ARDUINO_ESP32S3_DEV) || defined(ARDUINO_ESP32S3)
  #define BOARD_NAME "ESP32-S3"
#elif defined(ARDUINO_ESP32S2_DEV) || defined(ARDUINO_ESP32S2)
  #define BOARD_NAME "ESP32-S2"
#elif defined(ARDUINO_ESP32C3_DEV) || defined(ARDUINO_ESP32C3)
  #define BOARD_NAME "ESP32-C3"
#elif defined(ARDUINO_ESP32C6_DEV) || defined(ARDUINO_ESP32C6)
  #define BOARD_NAME "ESP32-C6"
#elif defined(ARDUINO_ESP32_DEV) || defined(ARDUINO_ESP32)
  #define BOARD_NAME "ESP32"
#else
  #define BOARD_NAME "Unknown Board"
#endif

#if defined(BOARD_FAM_ESP32)
  #define DEF_STEP_X 18
  #define DEF_DIR_X  19
  #define DEF_ENA_X  17
  #define DEF_STEP_Y 21
  #define DEF_DIR_Y  22
  #define DEF_ENA_Y  23
  #define DEF_STEP_Z 25
  #define DEF_DIR_Z  26
  #define DEF_ENA_Z  27
  #define DEF_STEP_E 32
  #define DEF_DIR_E  33
  #define DEF_ENA_E  34
#elif defined(BOARD_FAM_RPXX)
  #define DEF_STEP_X 6
  #define DEF_DIR_X  7
  #define DEF_ENA_X  8
  #define DEF_STEP_Y 9
  #define DEF_DIR_Y  10
  #define DEF_ENA_Y  11
  #define DEF_STEP_Z 12
  #define DEF_DIR_Z  13
  #define DEF_ENA_Z  14
  #define DEF_STEP_E 15
  #define DEF_DIR_E  16
  #define DEF_ENA_E  17
#else
  #define DEF_STEP_X 2
  #define DEF_DIR_X  3
  #define DEF_ENA_X  4
  #define DEF_STEP_Y 5
  #define DEF_DIR_Y  6
  #define DEF_ENA_Y  7
  #define DEF_STEP_Z 8
  #define DEF_DIR_Z  9
  #define DEF_ENA_Z  10
  #define DEF_STEP_E 11
  #define DEF_DIR_E  12
  #define DEF_ENA_E  13
#endif

#if defined(BOARD_FAM_ESP32)
  hw_timer_t* tmr=nullptr;
  void setupTimer(uint32_t us){
    if(tmr) timerEnd(tmr);
    tmr = timerBegin(0,80,true);
    extern void IRAM_ATTR isr();
    timerAttachInterrupt(tmr,&isr,true);
    timerAlarmWrite(tmr,us,true);
    timerAlarmEnable(tmr);
  }
  inline void setPWM(int pin,int chan,int freq,int bits){ ledcAttachPin(pin,chan); ledcSetup(chan,freq,bits); }
  inline void writePWMChan(int chan,int val){ ledcWrite(chan,val); }
#elif defined(BOARD_FAM_RPXX)
  #include <Timer.h>
  Timer tmr;
  volatile uint32_t isrPeriodUs=1000;
  void timerThunk(){ extern void isr(); isr(); }
  void setupTimer(uint32_t us){ isrPeriodUs=us; tmr.stop(); tmr.attach_us(timerThunk,isrPeriodUs); }
  inline void setPWM(int pin,int chan,int freq,int bits){ (void)chan; analogWriteResolution(bits); analogWriteFrequency(freq); pinMode(pin,OUTPUT); }
  inline void writePWMChan(int chan,int val){ (void)chan; }
#else
  void setupTimer(uint32_t){ }
  inline void setPWM(int,int,int,int){ }
  inline void writePWMChan(int,int){ }
#endif

class DriverIface{public:virtual void init()=0;virtual void enable(bool en)=0;virtual void setDir(bool cw)=0;virtual void stepOnce(bool cw)=0;};
class TB6600Driver:public DriverIface{int ps,pd,pe;bool aLow;public:TB6600Driver(int s,int d,int e,bool al=true):ps(s),pd(d),pe(e),aLow(al){}void init(){pinMode(ps,OUTPUT);pinMode(pd,OUTPUT);pinMode(pe,OUTPUT);digitalWrite(pe,aLow?HIGH:LOW);}void enable(bool en){digitalWrite(pe,aLow?(en?LOW:HIGH):(en?HIGH:LOW));}void setDir(bool cw){digitalWrite(pd,cw?HIGH:LOW);}void stepOnce(bool cw){(void)cw;digitalWrite(ps,HIGH);delayMicroseconds(2);digitalWrite(ps,LOW);delayMicroseconds(2);}};
class ULN2003Driver:public DriverIface{int a,b,c,d;int idx=0;const uint8_t seq[8][4]={{1,0,0,0},{1,1,0,0},{0,1,0,0},{0,1,1,0},{0,0,1,0},{0,0,1,1},{0,0,0,1},{1,0,0,1}};void apply(){digitalWrite(a,seq[idx][0]);digitalWrite(b,seq[idx][1]);digitalWrite(c,seq[idx][2]);digitalWrite(d,seq[idx][3]);}public:ULN2003Driver(int ia,int ib,int ic,int id):a(ia),b(ib),c(ic),d(id){}void init(){pinMode(a,OUTPUT);pinMode(b,OUTPUT);pinMode(c,OUTPUT);pinMode(d,OUTPUT);apply();}void enable(bool en){if(!en){digitalWrite(a,LOW);digitalWrite(b,LOW);digitalWrite(c,LOW);digitalWrite(d,LOW);}}void setDir(bool cw){(void)cw;}void stepOnce(bool cw){idx=cw?((idx+1)&7):((idx+7)&7);apply();delayMicroseconds(1000);}};

struct Axis{String label;DriverIface* drv=nullptr;String drvType;bool inv=false;float spu=80.0f;float maxF=3000.0f;bool en=false;float pos=0.0f;int minEnd=-1;int maxEnd=-1;};
#define MAX_AXES 8
Axis axes[MAX_AXES];int axisCount=0;

enum Mode{MODE_TEST=0,MODE_3DP=1,MODE_CNC=2};
Mode modeSel=MODE_TEST;
bool absMode=true;
float defF=1200.0f;

struct Heater{int pin=-1;int pwmCh=-1;int adcPin=-1;float target=0;float current=0;float kp=10.0f;float ki=0.02f;float kd=40.0f;float integ=0;float prevErr=0;float maxT=300.0f;float scale=300.0f;float offset=0.0f;} hotend,bed;
int fanPin=-1;int fanPWM=0;
int spindlePin=-1;int spindlePWMCh=-1;int spindleSpeed=0;
int mistPin=-1;int floodPin=-1;

struct Move{bool valid=false;int32_t steps[MAX_AXES];bool dirCW[MAX_AXES];int32_t err[MAX_AXES];int32_t maxSteps=0;uint32_t periodUs=1000;};
#define QLEN 48
volatile Move q[QLEN];volatile int qH=0,qT=0;

#if defined(BOARD_FAM_ESP32)
portMUX_TYPE mux=portMUX_INITIALIZER_UNLOCKED;
#else
volatile bool mux=false;
#endif

void ok(){Serial.println("ok");}
void err(const char* m){Serial.print("error:");Serial.println(m);}

Axis* findAxLabel(const String& n){for(int i=0;i<axisCount;i++)if(axes[i].label.equalsIgnoreCase(n))return &axes[i];return nullptr;}
Axis* findAxChar(char L){for(int i=0;i<axisCount;i++)if(axes[i].label.length()==1&&axes[i].label[0]==L)return &axes[i];return nullptr;}

bool enq(const Move& m){
#if defined(BOARD_FAM_ESP32)
  portENTER_CRITICAL(&mux);
  int nt=(qT+1)%QLEN;if(nt==qH){portEXIT_CRITICAL(&mux);return false;}
  q[qT]=m;q[qT].valid=true;qT=nt;portEXIT_CRITICAL(&mux);
#else
  int nt=(qT+1)%QLEN;if(nt==qH)return false;q[qT]=m;q[qT].valid=true;qT=nt;
#endif
  return true;
}

uint32_t feedToUs(float F,float primarySPU){float sps=(F/60.0f)*primarySPU;if(sps<1.0f)sps=1.0f;uint32_t us=(uint32_t)(1000000.0f/sps);if(us<100)us=100;return us;}

void heaterUpdate(Heater& h){
  if(h.pin<0)return;
  if(h.adcPin>=0){int r=analogRead(h.adcPin);float v=(float)r/4095.0f;h.current=v*h.scale+h.offset;if(h.current<0)h.current=0;if(h.current>h.maxT)h.current=h.maxT;}
  float e=h.target-h.current;h.integ+=e;h.integ=constrain(h.integ,-1000.0f,1000.0f);float d=e-h.prevErr;h.prevErr=e;float out=h.kp*e+h.ki*h.integ+h.kd*d;out=constrain(out,0.0f,255.0f);
#if defined(BOARD_FAM_ESP32)
  if(h.pwmCh>=0){writePWMChan(h.pwmCh,(int)out);}else{digitalWrite(h.pin,out>0?HIGH:LOW);}
#else
  analogWrite(h.pin,(int)out);
#endif
}

void IRAM_ATTR isr(){
#if defined(BOARD_FAM_ESP32)
  portENTER_CRITICAL_ISR(&mux);
#endif
  if(qH==qT){
#if defined(BOARD_FAM_ESP32)
    portEXIT_CRITICAL_ISR(&mux);
#endif
    return;
  }
  Move& m=const_cast<Move&>(q[qH]);
  if(!m.valid){qH=(qH+1)%QLEN;
#if defined(BOARD_FAM_ESP32)
    portEXIT_CRITICAL_ISR(&mux);
#endif
    return;
  }
  for(int i=0;i<axisCount;i++){
    int32_t s=abs(m.steps[i]);if(s==0)continue;m.err[i]+=s;
    if(m.err[i]>=m.maxSteps){
      m.err[i]-=m.maxSteps;
      Axis& A=axes[i];
      if(A.en&&A.drv){
        if(A.minEnd>=0&&digitalRead(A.minEnd)==LOW&&(!m.dirCW[i])){m.steps[i]=0;continue;}
        if(A.maxEnd>=0&&digitalRead(A.maxEnd)==LOW&&(m.dirCW[i])){m.steps[i]=0;continue;}
        A.drv->stepOnce(m.dirCW[i]);A.pos+=(m.dirCW[i]?(1.0f/A.spu):(-1.0f/A.spu));
      }
      m.steps[i]+=(m.dirCW[i]?-1:+1);
    }
  }
  bool done=true;for(int i=0;i<axisCount;i++)if(m.steps[i]!=0){done=false;break;}
  if(done){m.valid=false;qH=(qH+1)%QLEN;}
#if defined(BOARD_FAM_ESP32)
  timerAlarmWrite(tmr,m.periodUs,true);
  portEXIT_CRITICAL_ISR(&mux);
#else
#endif
}

void setPeriod(uint32_t us){
#if defined(BOARD_FAM_ESP32)
  if(!tmr)return;timerAlarmDisable(tmr);timerAlarmWrite(tmr,us,true);timerAlarmEnable(tmr);
#else
  isrPeriodUs=us;tmr.stop();tmr.attach_us(timerThunk,isrPeriodUs);
#endif
}

float fAfter(const String& s,char k,bool* f){int i=s.indexOf(k);if(i<0){if(f)*f=false;return 0.0f;}int j=i+1;String n;while(j<s.length()&&(isDigit(s[j])||s[j]=='.'||s[j]=='-'))n+=s[j++];if(f)*f=true;return n.toFloat();}
long lAfter(const String& s,char k,bool* f){int i=s.indexOf(k);if(i<0){if(f)*f=false;return 0;}int j=i+1;String n;while(j<s.length()&&(isDigit(s[j])||s[j]=='-'))n+=s[j++];if(f)*f=true;return n.toInt();}
bool word(const String& s,const String& key,String& out){int i=s.indexOf(key);if(i<0)return false;i+=key.length();while(i<s.length()&&s[i]==' ')i++;int j=i;while(j<s.length()&&s[j]!=' '&&s[j]!=','&&s[j]!=';'&&s[j]!='+'&&s[j]!='=')j++;out=s.substring(i,j);return true;}
bool wordEq(const String& s,const String& key,String& out){int i=s.indexOf(key);if(i<0)return false;i+=key.length();if(i<s.length()&&s[i]=='=')i++;while(i<s.length()&&s[i]==' ')i++;int j=i;while(j<s.length()&&s[j]!=' '&&s[j]!=','&&s[j]!=';'&&s[j]!='+')j++;out=s.substring(i,j);return true;}

void queueMoveWords(const String& ln,float F){
  Move m;m.maxSteps=0;float primarySPU=1.0f;
  for(int i=0;i<axisCount;i++){Axis& A=axes[i];if(F>A.maxF)F=A.maxF;}
  for(int i=0;i<axisCount;i++){
    Axis& A=axes[i];bool found=false;float val=0.0f;
    if(A.label.length()==1){val=fAfter(ln,A.label[0],&found);}else{String out;if(wordEq(ln,A.label,out)){val=out.toFloat();found=true;}}
    if(!found){m.steps[i]=0;m.dirCW[i]=true;m.err[i]=0;continue;}
    float tgt=absMode?val:(A.pos+val);float dlt=tgt-A.pos;int32_t st=(int32_t)round(dlt*A.spu);bool cw=st>=0;st=abs(st);
    if(st>m.maxSteps){m.maxSteps=st;primarySPU=A.spu;}
    m.steps[i]=cw?st:-st;m.dirCW[i]=cw^A.inv;m.err[i]=0;A.drv->setDir(m.dirCW[i]);
  }
  if(m.maxSteps==0){ok();return;}
  m.periodUs=feedToUs(F,primarySPU);
  if(!enq(m)){err("queue");return;}
  ok();
}

void queueArc(const String& ln,bool cw){
  bool ff;float F=fAfter(ln,'F',&ff);if(!ff)F=defF;
  Axis* Ax=findAxChar('X');Axis* Ay=findAxChar('Y');if(!Ax||!Ay){err("arc axes");return;}
  bool xf;float Xv=fAfter(ln,'X',&xf);bool yf;float Yv=fAfter(ln,'Y',&yf);bool iflag;float Iv=fAfter(ln,'I',&iflag);bool jflag;float Jv=fAfter(ln,'J',&jflag);
  float Xend=xf?(absMode?Xv:Ax->pos+Xv):Ax->pos;float Yend=yf?(absMode?Yv:Ay->pos+Yv):Ay->pos;float Xc=Ax->pos+Iv;float Yc=Ay->pos+Jv;
  float sx=Ax->pos-Xc,sy=Ay->pos-Yc,ex=Xend-Xc,ey=Yend-Yc;float rs=sqrtf(sx*sx+sy*sy);float a0=atan2f(sy,sx);float a1=atan2f(ey,ex);float dtheta=a1-a0;if(cw&&dtheta>0)dtheta-=2*M_PI;if(!cw&&dtheta<0)dtheta+=2*M_PI;
  int segments=max(12,(int)(fabs(dtheta)*50));float da=dtheta/segments;
  for(int s=1;s<=segments;s++){float a=a0+da*s;float xt=Xc+rs*cosf(a);float yt=Yc+rs*sinf(a);String seg=String("X")+String(xt,4)+" Y"+String(yt,4)+" F"+String(F,2);queueMoveWords(seg,F);}
}

void reportPos(){
  String s;for(int i=0;i<axisCount;i++){s+=axes[i].label+":"+String(axes[i].pos,3);if(i<axisCount-1)s+=" ";}Serial.println(s);ok();
}

void execG(const String& ln){
  bool f;int g=(int)lAfter(ln,'G',&f);if(!f){err("G");return;}
  if(g==0||g==1){bool ff;float F=fAfter(ln,'F',&ff);if(!ff)F=defF;queueMoveWords(ln,F);}
  else if(g==2||g==3){queueArc(ln,g==2);}
  else if(g==4){bool p;long ms=lAfter(ln,'P',&p);if(!p){err("G4");return;}delay(ms);ok();}
  else if(g==28){for(int i=0;i<axisCount;i++)axes[i].pos=0.0f;ok();}
  else if(g==38){bool ff;float F=fAfter(ln,'F',&ff);if(!ff)F=defF;queueMoveWords(ln,F);}
  else if(g==90){absMode=true;ok();}
  else if(g==91){absMode=false;ok();}
  else{err("G?");}
}

void execM(const String& ln){
  bool f;int m=(int)lAfter(ln,'M',&f);if(!f){err("M");return;}
  if(m==17){bool targeted=false;for(int i=0;i<axisCount;i++){char ax=axes[i].label.length()==1?axes[i].label[0]:0;if(ax&&ln.indexOf(ax)>=0){axes[i].en=true;axes[i].drv->enable(true);targeted=true;}}if(!targeted){for(int i=0;i<axisCount;i++){axes[i].en=true;axes[i].drv->enable(true);}}ok();}
  else if(m==18){bool targeted=false;for(int i=0;i<axisCount;i++){char ax=axes[i].label.length()==1?axes[i].label[0]:0;if(ax&&ln.indexOf(ax)>=0){axes[i].en=false;axes[i].drv->enable(false);targeted=true;}}if(!targeted){for(int i=0;i<axisCount;i++){axes[i].en=false;axes[i].drv->enable(false);}}ok();}
  else if(m==92){for(int i=0;i<axisCount;i++){if(axes[i].label.length()==1){char ax=axes[i].label[0];bool af;float v=fAfter(ln,ax,&af);if(af)axes[i].spu=v;}else{String out;if(wordEq(ln,axes[i].label,out))axes[i].spu=out.toFloat();}}ok();}
  else if(m==203){for(int i=0;i<axisCount;i++){if(axes[i].label.length()==1){char ax=axes[i].label[0];bool af;float v=fAfter(ln,ax,&af);if(af)axes[i].maxF=v;}else{String out;if(wordEq(ln,axes[i].label,out))axes[i].maxF=out.toFloat();}}ok();}
  else if(m==114){reportPos();}
  else if(m==115){Serial.print("FIRMWARE_NAME:UnifiedMotion ");Serial.println(BOARD_NAME);ok();}
  else if(m==104){bool sF;float t=fAfter(ln,'S',&sF);if(sF)hotend.target=t;ok();}
  else if(m==109){bool sF;float t=fAfter(ln,'S',&sF);if(sF)hotend.target=t;unsigned long st=millis();while(fabs(hotend.current-hotend.target)>1.5&&millis()-st<600000){heaterUpdate(hotend);delay(10);}ok();}
  else if(m==140){bool sF;float t=fAfter(ln,'S',&sF);if(sF)bed.target=t;ok();}
  else if(m==190){bool sF;float t=fAfter(ln,'S',&sF);if(sF)bed.target=t;unsigned long st=millis();while(fabs(bed.current-bed.target)>1.5&&millis()-st<600000){heaterUpdate(bed);delay(10);}ok();}
  else if(m==105){Serial.print("T:");Serial.print(hotend.current,1);Serial.print(" B:");Serial.println(bed.current,1);ok();}
  else if(m==106){bool sF;float v=fAfter(ln,'S',&sF);fanPWM=sF?(int)v:255;if(fanPin>=0){if(fanPWM<=0)digitalWrite(fanPin,LOW);else digitalWrite(fanPin,HIGH);}ok();}
  else if(m==107){if(fanPin>=0)digitalWrite(fanPin,LOW);ok();}
  else if(m==3||m==4){bool sF;int S=(int)fAfter(ln,'S',&sF);spindleSpeed=sF?S:spindleSpeed;if(spindlePin>=0){
#if defined(BOARD_FAM_ESP32)
    if(spindlePWMCh>=0)writePWMChan(spindlePWMCh,constrain(spindleSpeed,0,255));else digitalWrite(spindlePin,spindleSpeed>0?HIGH:LOW);
#else
    analogWrite(spindlePin,constrain(spindleSpeed,0,255));
#endif
  }ok();}
  else if(m==5){spindleSpeed=0;if(spindlePin>=0){
#if defined(BOARD_FAM_ESP32)
    if(spindlePWMCh>=0)writePWMChan(spindlePWMCh,0);else digitalWrite(spindlePin,LOW);
#else
    analogWrite(spindlePin,0);
#endif
  }ok();}
  else if(m==7){if(mistPin>=0)digitalWrite(mistPin,HIGH);ok();}
  else if(m==8){if(floodPin>=0)digitalWrite(floodPin,HIGH);ok();}
  else if(m==9){if(mistPin>=0)digitalWrite(mistPin,LOW);if(floodPin>=0)digitalWrite(floodPin,LOW);ok();}
  else if(m==740){
    String label;String out;if(word(ln,"M740 ",out))label=out;bool sf,df,ef,ifd,lfd;int ps=(int)lAfter(ln,'S',&sf),pd=(int)lAfter(ln,'D',&df),pe=(int)lAfter(ln,'E',&ef);int inv=(int)lAfter(ln,'I',&ifd),act=(int)lAfter(ln,'L',&lfd);if(!(sf&&df&&ef)){err("M740");return;}if(axisCount>=MAX_AXES){err("AXFULL");return;}auto* drv=new TB6600Driver(ps,pd,pe,(lfd?act!=0:true));drv->init();Axis& A=axes[axisCount++];A.label=label;A.drv=drv;A.drvType="TB6600";A.inv=(ifd?inv!=0:false);A.spu=80.0f;A.maxF=3000.0f;A.en=false;A.pos=0.0f;A.minEnd=-1;A.maxEnd=-1;ok();
  }else if(m==741){
    String label;String out;if(word(ln,"M741 ",out))label=out;bool af,bf,cf,df,ifd;int in1=(int)lAfter(ln,'A',&af),in2=(int)lAfter(ln,'B',&bf),in3=(int)lAfter(ln,'C',&cf),in4=(int)lAfter(ln,'D',&df);int inv=(int)lAfter(ln,'I',&ifd);if(!(af&&bf&&cf&&df)){err("M741");return;}if(axisCount>=MAX_AXES){err("AXFULL");return;}auto* drv=new ULN2003Driver(in1,in2,in3,in4);drv->init();Axis& A=axes[axisCount++];A.label=label;A.drv=drv;A.drvType="ULN2003";A.inv=(ifd?inv!=0:false);A.spu=2048.0f;A.maxF=600.0f;A.en=false;A.pos=0.0f;A.minEnd=-1;A.maxEnd=-1;ok();
  }else if(m==742){axisCount=0;ok();}
  else if(m==760){String out;if(wordEq(ln,"MODE",out)){out.toUpperCase();if(out=="TEST")modeSel=MODE_TEST;else if(out=="CNC")modeSel=MODE_CNC;else if(out=="3DP")modeSel=MODE_3DP;}ok();}
  else if(m==761){
    String out;
    if(wordEq(ln,"HOTEND_PIN",out)){hotend.pin=out.toInt();pinMode(hotend.pin,OUTPUT);hotend.pwmCh=0;
#if defined(BOARD_FAM_ESP32)
      setPWM(hotend.pin,hotend.pwmCh,1000,8);
#endif
    }
    if(wordEq(ln,"HOTEND_ADC",out)){hotend.adcPin=out.toInt();}
    if(wordEq(ln,"BED_PIN",out)){bed.pin=out.toInt();pinMode(bed.pin,OUTPUT);bed.pwmCh=1;
#if defined(BOARD_FAM_ESP32)
      setPWM(bed.pin,bed.pwmCh,1000,8);
#endif
    }
    if(wordEq(ln,"BED_ADC",out)){bed.adcPin=out.toInt();}
    if(wordEq(ln,"FAN_PIN",out)){fanPin=out.toInt();pinMode(fanPin,OUTPUT);}
    if(wordEq(ln,"SPINDLE_PIN",out)){spindlePin=out.toInt();pinMode(spindlePin,OUTPUT);spindlePWMCh=2;
#if defined(BOARD_FAM_ESP32)
      setPWM(spindlePin,spindlePWMCh,1000,8);
#endif
    }
    if(wordEq(ln,"MIST_PIN",out)){mistPin=out.toInt();pinMode(mistPin,OUTPUT);}
    if(wordEq(ln,"FLOOD_PIN",out)){floodPin=out.toInt();pinMode(floodPin,OUTPUT);}
    ok();
  }else if(m==762){
    String label;String out;if(word(ln,"M762 ",out))label=out;Axis* A=findAxLabel(label);if(!A){err("AX");return;}String v;if(wordEq(ln,"MIN",v)){A->minEnd=v.toInt();pinMode(A->minEnd,INPUT_PULLUP);}if(wordEq(ln,"MAX",v)){A->maxEnd=v.toInt();pinMode(A->maxEnd,INPUT_PULLUP);}ok();
  }else{err("M?");}
}

void execTest(const String& ln){
  String s=ln;String parts[64];int pc=0;int i=0;
  while(i<s.length()){while(i<s.length()&&(s[i]==' '||s[i]=='\t'))i++;int j=i;while(j<s.length()&&s[j]!='+'&&s[j]!=' '&&s[j]!='\t')j++;if(j>i){parts[pc++]=s.substring(i,j);}if(pc>=64)break;i=(j<s.length()&&s[j]=='+')?j+1:j+1;}
  if(pc<4){err("TEST");return;}
  long nMot=parts[0].toInt();String label=parts[1];long steps=parts[2].toInt();String dir=parts[3];String act=(pc>=5)?parts[4]:"";
  bool cw=dir.equalsIgnoreCase("cw")||dir.equalsIgnoreCase("clockwise");if(dir.equalsIgnoreCase("cc")||dir.equalsIgnoreCase("counter")||dir.equalsIgnoreCase("counterclockwise"))cw=false;
  if(act.equalsIgnoreCase("sel")){if(pc<6){err("SEL");return;}String list=parts[5];int p=0;while(p<list.length()){while(p<list.length()&&(list[p]==','||list[p]==' '))p++;int q=p;while(q<list.length()&&list[q]!=','&&list[q]!=' ')q++;String lab=list.substring(p,q);Axis* A=findAxLabel(lab);if(A){A->en=true;A->drv->enable(true);}p=q+1;}ok();return;}
  if(act.equalsIgnoreCase("stop")||act.equalsIgnoreCase("hlt")){
#if defined(BOARD_FAM_ESP32)
    portENTER_CRITICAL(&mux);qH=qT;portEXIT_CRITICAL(&mux);
#else
    qH=qT;
#endif
    ok();return;
  }
  Axis* A=findAxLabel(label);
  if(!A){
    String pS,pD,pE,pA,pB,pC,pD4;bool hS=wordEq(ln,"S",pS),hD=wordEq(ln,"D",pD),hE=wordEq(ln,"E",pE);bool hA=wordEq(ln,"A",pA),hB=wordEq(ln,"B",pB),hC=wordEq(ln,"C",pC),hD2=wordEq(ln,"D",pD4);
    if(hS&&hD&&hE){if(axisCount>=MAX_AXES){err("AXFULL");return;}auto* drv=new TB6600Driver(pS.toInt(),pD.toInt(),pE.toInt(),true);drv->init();Axis& Ax=axes[axisCount++];Ax.label=label;Ax.drv=drv;Ax.drvType="TB6600";Ax.en=true;drv->enable(true);}
    else if(hA&&hB&&hC&&hD2){if(axisCount>=MAX_AXES){err("AXFULL");return;}auto* drv=new ULN2003Driver(pA.toInt(),pB.toInt(),pC.toInt(),pD4.toInt());drv->init();Axis& Ax=axes[axisCount++];Ax.label=label;Ax.drv=drv;Ax.drvType="ULN2003";Ax.en=true;drv->enable(true);}
    else{err("PINS");return;}
    A=findAxLabel(label);
  }
  Move m;m.maxSteps=abs(steps);for(int n=0;n<axisCount;n++){m.steps[n]=0;m.dirCW[n]=true;m.err[n]=0;}
  bool d=cw^A->inv;int idx=(int)(A-axes);m.steps[idx]=cw?abs(steps):-abs(steps);m.dirCW[idx]=d;A->drv->setDir(d);m.periodUs=1000;if(!enq(m)){err("QUEUE");return;}ok();
}

void execLine(const String& lnIn){
  String ln=lnIn;ln.trim();if(!ln.length())return;char c=ln[0];
  if(c=='G'){execG(ln);}
  else if(c=='M'){execM(ln);}
  else{if(modeSel==MODE_TEST)execTest(ln);else execTest(ln);}
}

void readSerial(){
  static String buf;
  while(Serial.available()){
    char ch=(char)Serial.read();
    if(ch=='\r')continue;
    if(ch=='\n'){buf.trim();if(buf.length())execLine(buf);buf="";}
    else buf+=ch;
  }
}

void setupTimerInitial(){setupTimer(1000);}

void setup(){
  Serial.begin(115200);delay(200);
  Serial.print("Firmware start: ");Serial.println(BOARD_NAME);
  Serial.println("echo:UnifiedMotion TEST/CNC/3DP");
  setupTimerInitial();
  auto* xdrv=new TB6600Driver(DEF_STEP_X,DEF_DIR_X,DEF_ENA_X,true);xdrv->init();Axis& X=axes[axisCount++];X.label="X";X.drv=xdrv;X.drvType="TB6600";
  auto* ydrv=new TB6600Driver(DEF_STEP_Y,DEF_DIR_Y,DEF_ENA_Y,true);ydrv->init();Axis& Y=axes[axisCount++];Y.label="Y";Y.drv=ydrv;Y.drvType="TB6600";
  auto* zdrv=new TB6600Driver(DEF_STEP_Z,DEF_DIR_Z,DEF_ENA_Z,true);zdrv->init();Axis& Z=axes[axisCount++];Z.label="Z";Z.drv=zdrv;Z.drvType="TB6600";
  auto* edrv=new TB6600Driver(DEF_STEP_E,DEF_DIR_E,DEF_ENA_E,true);edrv->init();Axis& E=axes[axisCount++];E.label="E";E.drv=edrv;E.drvType="TB6600";
}

void loop(){
  readSerial();
  heaterUpdate(hotend);
  heaterUpdate(bed);
  static uint32_t last=1000;
#if defined(BOARD_FAM_ESP32)
  portENTER_CRITICAL(&mux);
  if(qH!=qT&&q[qH].valid){uint32_t p=q[qH].periodUs;portEXIT_CRITICAL(&mux);if(p!=last&&p>=100){setPeriod(p);last=p;}}else{portEXIT_CRITICAL(&mux);}
#else
  if(qH!=qT&&q[qH].valid){uint32_t p=q[qH].periodUs;if(p!=last&&p>=100){setPeriod(p);last=p;}}
#endif
}