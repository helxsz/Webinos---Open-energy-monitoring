// afafaddd
//--------------------------------------------------------------------------
// Ethernet
//--------------------------------------------------------------------------
#include <EtherCard.h>
#include <NanodeUNIO.h>

// ethernet interface mac address
static byte mymac[] = { 0x74,0x69,0x69,0x2D,0x30,0x31 };
// ethernet interface ip address
static byte myip[] = { 192,168,210,203 };
// gateway ip address
static byte gwip[] = { 192,168,210,1 };
// remote website ip address and port
static byte hisip[] = { 192,168,210,2 };
// remote website name
char website[] PROGMEM = "google.com";
#define APIKEY  "b872449aa3ba74458383a798b740a378"

// buffer 
byte Ethernet::buffer[500];   // a very small tcp/ip buffer is enough here
static BufferFiller bfill;  // used as cursor while filling the buffer
char line_buf[150];                        // Used to store line of http reply header
static uint32_t timer;/////////////////////

//https://github.com/thiseldo/EtherCardExamples/blob/master/EtherCard_RESTduino/EtherCard_RESTduino.ino
// https://github.com/openenergymonitor/NanodeRF/blob/master/NanodeRF_singleCT_RTCrelay_GLCDtemp/NanodeRF_singleCT_RTCrelay_GLCDtemp.ino
#include <Ports.h>
#include <RF12.h>
#include <JeeLib.h>
#include <avr/pgmspace.h>

#define DEBUG 0

#include <SPI.h>
#include <SRAM9.h>
typedef struct {
    char id[12];             /* id */
    byte types[5];              /* type */    
    byte channel;  // 0 -31
}Mote;
Mote mote;
byte device_num =0;
#define type_mote 0;
#define type_actuator 1;



int INDEX_MOTE_LENGTH = 500;
int LIST_MOTE_BEGIN = 1000;
////////////////////////////////////////////
#include <avr/eeprom.h>
#define CONFIG_EEPROM_ADDR ((byte*) 0x10)

// configuration, as stored in EEPROM
struct Config {
    byte band;
    byte group;
    byte valid; // keep this as last byte
} config;

static void loadConfig() {
    for (byte i = 0; i < sizeof config; ++i)
        ((byte*) &config)[i] = eeprom_read_byte(CONFIG_EEPROM_ADDR + i);
    if (config.valid != 253) {
        config.valid = 253;
        config.band = 8;
        config.group = 1;
    }
    byte freq = config.band == 4 ? RF12_433MHZ :
                config.band == 8 ? RF12_868MHZ :
                                   RF12_915MHZ;
}

static void saveConfig() {
    for (byte i = 0; i < sizeof config; ++i)
        eeprom_write_byte(CONFIG_EEPROM_ADDR + i, ((byte*) &config)[i]);
}


////////////////////////////////////////////
#include <avr/pgmspace.h>
prog_char type_temp[] PROGMEM = "temperature";   // "String 0" etc are strings to store - change to suit.
prog_char type_hum[] PROGMEM = "humidity";
prog_char type_light[] PROGMEM = "light";
prog_char type_volt[] PROGMEM = "voltage";
prog_char type_elec[] PROGMEM = "electrcity";

prog_char type_lamb[] PROGMEM = "http://webinos.org/api/motes.lamb";

PROGMEM const char *sensor_table[] = 	   // change "string_table" name to suit
{   
  type_temp,
  type_hum,
  type_light,
  type_volt,
  type_elec 
};

PROGMEM const char *actuator_table[] = 	   // change "string_table" name to suit
{   
  type_lamb
};


byte s_temp = 0;
byte s_hum =1;
byte s_light =2;
byte s_volt =3;
byte s_elec =4;

byte s_lamb =10;
////////////////////////////////////////////
#define MYNODE 1            
#define freq RF12_868MHZ      // frequency
#define group 1            // network group
//---------------------------------------------------
// Data structures for transfering data between units
//---------------------------------------------------
typedef struct { 
               int temperature, humidity,light;
               char mac[15]; 
} PayloadTX;
PayloadTX emonen;    

// The RF12 data payload - a neat way of packaging data when sending via RF - JeeLabs
// must be same structure as transmitted from emonTx
typedef struct
{
  int ct1;		     // current transformer 1
  int ct2;                 // current transformer 2 - un-comment as appropriate 
  //int ct3;                 // current transformer 1 - un-comment as appropriate 
  int supplyV;               // emontx voltage
  char mac[12]; 
} Payload;
Payload emontx;     

//---------------------------------------------------------------------
// The PacketBuffer class is used to generate the json string that is send via ethernet - JeeLabs
//---------------------------------------------------------------------







const byte redLED = 6;                     // NanodeRF RED indicator LED
const byte greenLED = 5;                   // NanodeRF GREEN indicator LED

byte ethernet_error = 0;                   // Etherent (controller/DHCP) error flag
byte rf_error = 0;                         // RF error flag - high when no data received 
byte ethernet_requests = 0;                // count ethernet requests without reply                 

byte dhcp_status = 0;
byte dns_status = 0;

byte emonglcd_rx = 0;                      // Used to indicate that emonglcd data is available
byte data_ready=0;                         // Used to signal that emonen data is ready to be sent
unsigned long last_rf;                    // Used to check for regular emonen data - otherwise error


char okHeader[] PROGMEM =
    "HTTP/1.0 200 OK\r\n"
    "Content-Type: text/html\r\n"
    "Pragma: no-cache\r\n"
    "\r\n" ;
 
char responseHeader[] PROGMEM =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/html\r\n"
    "Access-Control-Allow-Origin: *\r\n"
    "\r\n" ;


// called when the client request is complete
static void my_result_cb (byte status, word off, word len) {
  //Serial.print("<<< reply ");Serial.print(millis() - timer);Serial.println(" ms");
  Serial.println("server reply");
  //
  //Serial.println((const char*) Ethernet::buffer + off);
}


uint16_t http200ok(void)
{
  bfill = ether.tcpOffset();
  bfill.emit_p(PSTR(
    "HTTP/1.0 200 OK\r\n"
    "Content-Type: text/html\r\n"
    "Pragma: no-cache\r\n"
    "\r\n"));
  return bfill.position();
}

uint16_t http404(void)
{
  bfill = ether.tcpOffset();
  bfill.emit_p(PSTR(
    "HTTP/1.0 404 OK\r\n"
    "Content-Type: text/html\r\n"
    "\r\n"));
  return bfill.position();
}

// prepare the webpage by writing the data to the tcp send buffer
uint16_t print_webpage()
{
  bfill = ether.tcpOffset();
  bfill.emit_p(PSTR(
    "HTTP/1.0 200 OK\r\n"
    "Content-Type: text/html\r\n"
    "Pragma: no-cache\r\n"
    "\r\n"
    "<html><body>Invalid option selected</body></html>"));
  return bfill.position();
}
     
void getMac()
{
  boolean r;
  NanodeUNIO unio(NANODE_MAC_DEVICE) ;
  r= unio.read(mymac, NANODE_MAC_ADDRESS, 6) ;
  if (r) Serial.println("success");
  else Serial.println("failure");
  sprintf(line_buf,"%02X:%02X:%02X:%02X:%02X:%02X",
          mymac[0],mymac[1],mymac[2],
          mymac[3],mymac[4],mymac[5]);
  //Serial.print("MAC address is ");
  Serial.println(line_buf);
}

void setup () {
 // config the leds 
 
  Serial.begin(9600);  
  /*
  for (int i = 0; i < 5; i++)
  {
    strcpy_P(line_buf, (char*)pgm_read_word(&(sensor_table[i]))); // Necessary casts and dereferencing, just copy. 
    Serial.println( line_buf );
  } 
  */ 
 testram();

 loadConfig();
 
 pinMode(redLED, OUTPUT);             
 pinMode(greenLED, OUTPUT);     
 delay(100);  
  
  if (ether.begin(sizeof Ethernet::buffer, mymac) == 0) 
    //Serial.println( "Failed to access Ethernet controller");
        

  if (!ether.dhcpSetup())
    Serial.println("DHCP failed");

  ether.printIp("IP:  ", ether.myip);
  ether.printIp("GW:  ", ether.gwip);  
  ether.printIp("DNS: ", ether.dnsip);  
 /**/
  // get the mac address of this device
  getMac();  
  // config the ethernets
  ether.staticSetup(myip, gwip);

  

  while (ether.clientWaitingGw())
    ether.packetLoop(ether.packetReceive());
  Serial.println("Gateway found");

  #if 1
  // use DNS to locate the IP address we want to ping
  if (!ether.dnsLookup(PSTR("www.abcd.com")))
    Serial.println("abcd DNS failed");
  #else
  ether.parseIp(ether.hisip, "192.168.210.5");  // doesn't know what it means
  #endif
  ether.printIp("Server: ", ether.hisip);
  ether.hisport = 8080; 
  Serial.println(ether.hisip[0]);
  ether.copyIp(ether.hisip, hisip);  


 rf12_initialize(MYNODE, RF12_868MHZ, 1);    
}



void loop () {
  
  byte types[5];
  memset(&emontx, -1, 5);
  memset(&emontx, 0, sizeof(emontx));
  memset(&emonen, 0, sizeof(emonen));
  
  if (millis() > timer) {
    timer = millis() + 5000;
    Serial.print("polling   ........................");
    Serial.println( freeRam ());     
  }    
  
  // http://www.22balmoralroad.net/wordpress/wp-content/uploads/homeBase.pde
  if (rf12_recvDone() && rf12_crc == 0 )
  {
      //rf12_len == sizeof emonen

      //Serial.print("rf12_hdr=");Serial.print(rf12_hdr,HEX);Serial.print("     ");
      //Serial.print("RF12_HDR_DST=");Serial.print(rf12_hdr & RF12_HDR_DST,HEX);Serial.println("     ");
      //Serial.print("RF12_HDR_CTL=");Serial.print(rf12_hdr & RF12_HDR_CTL,HEX);Serial.println("     "); // what it means
      //http://scurvyrat.com/2011/05/24/getting-the-nodeid-in-a-rf12-packet/
      byte SenderID = (RF12_HDR_MASK & rf12_hdr);
      Serial.print("SENDID:");Serial.println(SenderID,HEX);Serial.println("     ");
      /*
if (!rf12_canSend())
{ 
    Serial.println("canSend");
    delay(5);   
    rf12_sendStart( (SenderID|RF12_HDR_DST ), &emontx, sizeof emontx);
    rf12_sendWait(2); 
}
*/
      //http://www.22balmoralroad.net/wordpress/wp-content/uploads/homeBase.pde
      //int node_id = (rf12_hdr & 0x1F);
      //Serial.print("receiverID:");Serial.print( node_id );Serial.println("    "); 
       /*      
       // http://talk.jeelabs.net/topic/727
      if (rf12_hdr == (RF12_HDR_DST | RF12_HDR_CTL | MYNODE)) // ?
      {
        //Serial.println("receiving something for this node");         
      }
      if ((rf12_hdr & RF12_HDR_CTL) == 0)
      {
        Serial.println("receiving something for this node"); 
      }else{
        Serial.println("receiving something for ANOTHER node"); 
      }  
          
      if(RF12_WANTS_ACK) //if they want an ACK packet  // http://evolveelectronics.tumblr.com/
      {
            Serial.println("want an ACK packet");
            rf12_sendStart(RF12_ACK_REPLY,0,0);
      }
      */
          /* 
    /////////////////////// PROBLEM ///////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////
      //// test resend the packet back  
      delay(5);
      rf12_sendStart( (RF12_HDR_ACK |RF12_HDR_DST | 18), &emonen, sizeof emonen);
      rf12_sendWait(2);   

    /////////////////////////////////////////////////////////////////////////
      */ 
    /*  http://www.22balmoralroad.net/wordpress/wp-content/uploads/homeBase.pde
    incNodeData = *(Payload*) rf12_data;
    incNodeType = incNodeData.type;
    switch(incNodeType) {
       case 1:
          incRoomNodeData = *(RoomNode*) incNodeData.data;
          sprintf(str,"{\"type\":%d,\"roomnode_ID\":%d,\"roomnode_light\":%d,\"roomnode_moved\":%d,\"roomnode_humi\":%d,\"roomnode_temp\":%d,\"roomnode_lobat\":%d}",incNodeType, incNodeID, incRoomNodeData.light,incRoomNodeData.moved,incRoomNodeData.humi,incRoomNodeData.temp,incRoomNodeData.lobat);
          break;
       case 2:
          incemonenData = *(emonen*) incNodeData.data;
          sprintf(str,"{\"type\":%d,\"emonen_ID\":%d,\"emonen_ctA\":%d,\"emonen_ctB\":%d,\"nPulse\":%d,\"emonen_temp1\":%d,\"emonen_temp2\":%d,\"emonen_temp3\":%d,\"emonen_V\":%d}",incNodeType, incNodeID,incemonenData.ct1, incemonenData.ct2, incemonenData.nPulse, incemonenData.temp1,incemonenData.temp2,incemonenData.temp3,incemonenData.supplyV);
          break;
    } */        
    // Flash LED:
    digitalWrite(6, HIGH);
    delay(100);
    digitalWrite(6, LOW);    
    
#ifdef DEBUG 
Serial.print("receive packets   ");Serial.print(sizeof(emonen));Serial.print(  "   :    ");Serial.println((int)rf12_len);
#endif
    if( rf12_len == sizeof emontx){
       memcpy(&emontx, (byte*) rf12_data, sizeof(emontx));
              
#ifdef DEBUG       
Serial.print("ct1:");    Serial.print(emontx.ct1);                // Add CT 1 reading 
Serial.print(",ct2:");    Serial.println(emontx.ct2);
Serial.print(",mac:");    Serial.println(emontx.mac);
#endif

       if(!findDevice(emontx.mac))
       {        
         types[0] = s_elec;
         types[1] = s_elec;
         types[2] = -1; types[3] = -1; types[4] = -1;
         
         storeDevice(emontx.mac,types,SenderID);
       }

       
       memset(&line_buf,0,sizeof(line_buf));    
       sprintf(line_buf,"{\'ct1\':%d,\'ct2\':%d,\'mac\':\'%s\'}", emontx.ct1,emontx.ct2,"cfcfcfcf");  
       ether.browseUrl(PSTR("/test?apikey="APIKEY"&data="), line_buf, NULL, my_result_cb);        
    }
    
    if(rf12_len == sizeof emonen)
    {
       // Copy the received data into payload:
       memcpy(&emonen, (byte*) rf12_data, sizeof(emonen));
       byte lenfth = rf12_len;
#ifdef DEBUG                         
   //Serial.print("mac:");Serial.println(emonen.mac);
   //Serial.println(strlen(emonen.mac));
#endif       
       if(strcmp(emonen.mac,"000000000000")==0 || strlen(emonen.mac)==0){
         Serial.println("NO MAC ");
         goto NO_MAC;
       }
       

       if(!findDevice(emonen.mac))
       {        
         types[0] = s_temp;
         types[1] = s_hum;
         types[2] = s_light;
         storeDevice(emonen.mac,types,SenderID);
       }
       int temperature = emonen.temperature;
       int humidity = emonen.humidity;
       char mac1[12]; 
       strcpy(mac1,emonen.mac);
  
#ifdef DEBUG
//Serial.print("temp:"); Serial.print(emonen.temperature);Serial.print(" "); 
//Serial.print("hum:"); Serial.print(emonen.humidity);Serial.print(" ");
//Serial.print("light:"); Serial.print(emonen.light);Serial.print(" ");
Serial.print("mac:"); Serial.println(emonen.mac);
#endif 
       
       
       memset(&line_buf,0,sizeof(line_buf));    
       sprintf(line_buf,"{\'temperature\':%d,\'humidity\':%d,\'light\':%d,\'mac\':\'%s\'}", emonen.temperature,emonen.humidity,emonen.light,emonen.mac);  
       //sprintf(line_buf,"[{\'sensorId\':\'%s\',\'type\':\'sensor.temperature\',\'data\':[%d]},{\'sensorId\':\'%s\',\'type\':\'sensor.humidity\',\'data\':[%d]}]",temid,emonen.temperature,humid,emonen.humidity); 
       //Serial.print("````````````````2");Serial.println(line_buf);         
       ether.browseUrl(PSTR("/test?apikey="APIKEY"&data="), line_buf, NULL, my_result_cb); 
     }
    
    //////////////////////////////////////////////////////////////////////////
    //Serial.println(millis()-last_rf);
         //(RF12_HDR_DST | masterNode)

 
    
    NO_MAC:
    last_rf = millis();     
    
    data_ready = 1;                                                // data is ready
    rf_error = 0;
    
   }  
    uint16_t  dat_p;
    // read packet, handle ping and wait for a tcp packet:
    dat_p=ether.packetLoop(ether.packetReceive());   
    if(dat_p==0){
      // no http request
      return;
    }
    if (strncmp("POST ",(char *)&(Ethernet::buffer[dat_p]),5)==0){
      // head, post and other methods:
Serial.println("post ");
      dat_p = process_request(1,(char *)&(Ethernet::buffer[dat_p+5]));
      goto SENDTCP;
    }
    // tcp port 80 begin
    if (strncmp("GET ",(char *)&(Ethernet::buffer[dat_p]),4)!=0){
      // head, post and other methods:
Serial.println("GET ");
      dat_p = print_webpage();
      goto SENDTCP;
    }
    
    // just one web page in the "root directory" of the web server
    if (strncmp("/ ",(char *)&(Ethernet::buffer[dat_p+4]),2)==0){
#ifdef DEBUG
Serial.println("GET / request");
#endif
      dat_p = print_webpage();
      goto SENDTCP;
    }
    dat_p = process_request(0,(char *)&(Ethernet::buffer[dat_p+4]));
    
   SENDTCP:
      if( dat_p )
        ether.httpServerReply( dat_p);

  delay( 34 );
}
#define CMDBUF 100
//-------------------------------------------------------------------
// -- http --
//

int16_t process_request(byte method, char *str)
{
  memset(line_buf,NULL,sizeof(line_buf));
  int8_t index = 0;
  
#ifdef DEBUG
  //Serial.println( str );
#endif

  char ch = str[index];
  
  while( ch != ' ' && index < CMDBUF) {
    line_buf[index] = ch;
    index++;
    ch = str[index];
  }
  line_buf[index] = '\0';

#ifdef DEBUG
  
#endif

  // convert clientline into a proper
  // string for further processing
  //String urlString = String(line_buf);
  // extract the operation
  //String op = urlString.substring(0,urlString.indexOf(' '));
  // we're only interested in the first part...
  //urlString = urlString.substring(urlString.indexOf('/'), urlString.indexOf(' ', urlString.indexOf('/')));
  // put what's left of the URL back in client line
  //urlString.toCharArray(line_buf, CMDBUF);
  // get the first two parameters
  char *pin = strtok(line_buf,"/");
  char *value = strtok(NULL,"/");
  char *action = strtok(NULL,"/");
  // this is where we actually *do something*!
  boolean found = false;
   
  char vv[20];
  strcpy(vv,value);
     if(strncmp(pin, "sensors", 7) == 0&& value ==NULL)
     {
#ifdef DEBUG
Serial.println("motes");  
#endif       
       
       if(method == 0)
       getInfoList(0);
       else
       http404();
       // list of motes       
     }else if(strncmp(pin, "actuators", 9) == 0 && value ==NULL)
     {
       // list of actuators
#ifdef DEBUG
Serial.println("actuators");  
#endif        
       if(method == 0)
       getInfoList(1);
       else
       http404();
     }else if(strncmp(pin, "actuators", 8) == 0 && value !=NULL)
     {
       // actuator info
#ifdef DEBUG
Serial.print("single actuator  id:");
Serial.println(value);  
#endif        

       if(method == 0)
       getInfo(0,vv);
       else
       {
         Serial.println(action);
         //getA(str);
         int SenderID = getChannel(value);
         Serial.print(",,,,,,,,,,,,,,,,");Serial.println(SenderID);
if (!rf12_canSend())
{ 
    Serial.println("canSend");
    delay(5);   
    
    rf12_sendStart( (SenderID|RF12_HDR_DST ), &emontx, sizeof emontx);
    rf12_sendWait(2); 
}
         
         http200ok();
       }  
     }else if(strncmp(pin, "sensors", 6) == 0 && value !=NULL)
     {
#ifdef DEBUG
Serial.print("singel mote  id:");
Serial.println(value);
#endif          
       // mote info

       if(method == 0)
       getInfo(0,vv);
       else
       {
         //getA(str);
         Serial.println(action);
         int SenderID = getChannel(value);
         Serial.print(",,,,,,,,,,,,,,,,");Serial.println(SenderID);
if (!rf12_canSend())
{ 
    Serial.println("can  not  Send");
    delay(5);   
    
    rf12_sendStart( (SenderID|RF12_HDR_DST ), &emontx, sizeof emontx);
    rf12_sendWait(2); 
}
else
{
    Serial.println("can   Send");
    delay(5);   
    
    rf12_sendStart( (SenderID|RF12_HDR_DST ), &emontx, sizeof emontx);
    rf12_sendWait(2);   
}
         http200ok();
       }       
     }  
      return bfill.position();    
}

/////////////////////////////////////////////////
// called when the client request is complete
static void callback (byte status, word off, word len) {
  //Serial.println(">>>");    
    //get_header_line(2, off);
    //get_header_line("X-Powered-By",off);
    //Serial.println(line_buf);
    
  get_reply_data(off);
#ifdef DEBUG
Serial.print("body:");
Serial.println(line_buf);
#endif  

  if (strcmp(line_buf,"ok")) 
  {
    Serial.println("ok recieved"); //request_attempt = 0;
  }    
}

int getA(char *str)
{
   Serial.println(str);
  memset(line_buf,NULL,sizeof(line_buf));

    uint16_t pos = 0;
    int line_num = 0;
    int line_pos = 0;
    
    // Skip over header until data part is found
    while (str[pos]) {
      if (str[pos-1]=='\n' && str[pos]=='\r') break;
      pos++; 
    }
    pos+=4;
    while (str[pos])
    {
      if (line_pos<49) {line_buf[line_pos] = str[pos]; line_pos++;} else break;
      pos++; 
    }
    line_buf[line_pos] = '\0';
 
  return 0;   
}

int get_header_line(char* line,word off)
{
  memset(line_buf,NULL,sizeof(line_buf));
  if (off != 0)
  {
    uint16_t pos = off;
    int line_num = 0;
    int line_pos = 0;
    
    while (Ethernet::buffer[pos])
    {
      if (Ethernet::buffer[pos]=='\n')
      {
        line_num++; line_buf[line_pos] = '\0';
        line_pos = 0;
        //if (line_num == line) return 1;
        if (strncmp(line,line_buf,50)==0)  return 1;
       
      }
      else
      {
        if (line_pos<49) {line_buf[line_pos] = Ethernet::buffer[pos]; line_pos++;}
      }  
      pos++; 
    } 
  }
  return 0;
}

int get_reply_data(word off)
{
  memset(line_buf,NULL,sizeof(line_buf));
  if (off != 0)
  {
    uint16_t pos = off;
    int line_num = 0;
    int line_pos = 0;
    
    // Skip over header until data part is found
    while (Ethernet::buffer[pos]) {
      if (Ethernet::buffer[pos-1]=='\n' && Ethernet::buffer[pos]=='\r') break;
      pos++; 
    }
    pos+=4;
    while (Ethernet::buffer[pos])
    {
      if (line_pos<49) {line_buf[line_pos] = Ethernet::buffer[pos]; line_pos++;} else break;
      pos++; 
    }
    line_buf[line_pos] = '\0';
  }
  return 0;
}

///////////////////////////////////////////////////////////////////////////////


int getLength()
{
  SRAM9.readstream(INDEX_MOTE_LENGTH);   // start address from 0   
  byte t = SRAM9.RWdata(0xFF);
  SRAM9.closeRWstream();
  return t;
}

void storeDevice(char *id,byte *type, byte channel){
  int length = 0;
  
#ifdef DEBUG
Serial.print("store device   ");Serial.println(strlen(id));
#endif  
  length = getLength();
  SRAM9.writestream(LIST_MOTE_BEGIN +length*sizeof(Mote));   // start address from 0
  /// store id
  for(byte i=0;i<12;i++){
    if(i<strlen(id))
    SRAM9.RWdata(id[i]);
    else 
    SRAM9.RWdata(0);
  }
  /// type
#ifdef DEBUG
//Serial.print("type length:");Serial.println(sizeof(type));
#endif  
  
  for(byte i=0;i<5;i++) {
    Serial.println((int)type[i]);
    if(i<=sizeof(type))
    SRAM9.RWdata(type[i]);
    else 
    SRAM9.RWdata(-1);
  }  
  
  SRAM9.RWdata(channel);

  // write length
  SRAM9.writestream(INDEX_MOTE_LENGTH);
  SRAM9.RWdata(++length);
  SRAM9.closeRWstream();

#ifdef DEBUG
  //Serial.print("len:");  Serial.println(length);
#endif  
   
}

boolean findDevice(char *id){
  // empty the mote structure
#ifdef DEBUG
  // Serial.print("findDevice   ");Serial.println(id);  
#endif   
  // flag to break 
  boolean found = false;
  SRAM9.readstream(INDEX_MOTE_LENGTH);   // start address from 0      
  int length = SRAM9.RWdata(0xFF); // get the length of devices
  Serial.print("length:");Serial.println(length);
  for(int i=0;i<length;i++)
  {  
    if(found ==true) break;    
    SRAM9.readstream(LIST_MOTE_BEGIN+i*sizeof(Mote));   // start address from 0
     // id
    //line_buf
    memset(line_buf,0,strlen(line_buf));
    for(int j=0;j<12;j++)
    line_buf[j]= SRAM9.RWdata(0xFF);
Serial.print("id:  ");Serial.print(i);Serial.print("  ");Serial.print(line_buf);Serial.print(" compare ");Serial.println(id);
    if(strncmp(line_buf,id,12)==0)
    {
      found = true;
#ifdef DEBUG
Serial.print("found:    ");Serial.println(id);
        for(int j=0;j<5;j++)
        SRAM9.RWdata(0xFF);
        
Serial.print("channel:");Serial.println((int)SRAM9.RWdata(0xFF));
#endif 
      break;   
    }
   
  }
  SRAM9.closeRWstream();
  return found;  
}


boolean getChannel(char *id){
  
  int channel  = -1;
  // empty the mote structure
#ifdef DEBUG
  // Serial.print("findDevice   ");Serial.println(id);  
#endif   
  // flag to break 
  boolean found = false;
  SRAM9.readstream(INDEX_MOTE_LENGTH);   // start address from 0      
  int length = SRAM9.RWdata(0xFF); // get the length of devices
  //Serial.print("length:");Serial.println(length);
  for(int i=0;i<length;i++)
  {  
    if(found ==true) break;    
    SRAM9.readstream(LIST_MOTE_BEGIN+i*sizeof(Mote));   // start address from 0
     // id
    //line_buf
    memset(line_buf,0,strlen(line_buf));
    for(int j=0;j<12;j++)
    {
      if(j>5)
      line_buf[j-6]= SRAM9.RWdata(0xFF);
      else
      SRAM9.RWdata(0xFF);
    }
Serial.print("id:  ");Serial.print(i);Serial.print("  ");Serial.print(line_buf);Serial.print(" compare ");Serial.println(id);
    if(strncmp(line_buf,id,6)==0)
    {
      found = true;
#ifdef DEBUG
Serial.print("found:    ");Serial.println(id);
        for(int j=0;j<5;j++)
        SRAM9.RWdata(0xFF);
        
channel = (int)SRAM9.RWdata(0xFF);
Serial.print("channel:");Serial.println(channel);
#endif 
      break;   
    }
   
  }
  SRAM9.closeRWstream();
  return channel;  
}


void testram()
{
  SRAM9.writestream(0);  // start address from 0
  unsigned long stopwatch = millis(); //start stopwatch
  for(unsigned int i = 0; i < 32768; i++)
    SRAM9.RWdata(0x00); //write to every SRAM address 
  //Serial.print(millis() - stopwatch);
  //Serial.println("   ms to write full SRAM");
  SRAM9.readstream(0);   // start address from 0 

  for(unsigned int i = 0; i < 32768; i++)
  {
    if(SRAM9.RWdata(0xFF) != 0x00)  //check every address in the SRAM
    {
#ifdef DEBUG
//Serial.println("error in location  ");
//Serial.println(i);
#endif 
      break;
    }//end of print error
    if(i == 32767)
    {
      #ifdef DEBUG
      //Serial.println("no errors in the 32768 bytes");
      #endif  
    }
   }//end of get byte
  SRAM9.closeRWstream();
}

static int freeRam () {
  extern int __heap_start, *__brkval; 
  int v; 
  return (int) &v - (__brkval == 0 ? (int) &__heap_start : (int) __brkval); 	
}

void getInfoList(byte devicegroup)
{
  SRAM9.readstream(INDEX_MOTE_LENGTH);   // start address from 0   
  int length = (int)SRAM9.RWdata(0xFF); // get the length of devices
  Serial.print("len:");Serial.println((int)length);Serial.println(length,HEX);  
   bfill = ether.tcpOffset();
   bfill.emit_p(PSTR(
        "HTTP/1.0 200 OK\r\n"
        "Content-Type: text/html\r\n"
        "Pragma: no-cache\r\n"
        "\r\n"
        "["));
  //Serial.println(" ---getInfoList ");
  char id[15]; char tempid[15];boolean created = false;
  for(int i=0;i<length;i++)
  {      
    SRAM9.readstream(LIST_MOTE_BEGIN+i*sizeof(Mote));   // start address from 0  
     // id
    memset(line_buf,0,150); 
    memset(id,0,15); 
    for(byte j=0;j<12;j++)
    {
      byte a = SRAM9.RWdata(0xFF);
      if(j>5)
      id[j-6]= a;
     
    }
#ifdef DEBUG
//Serial.print(" --------------------------------------------- ");Serial.println(id);
#endif 

    int type = -1;
 
    for(byte j=0;j<5;j++){
          
      type = (int)SRAM9.RWdata(0xFF);
#ifdef DEBUG
// Serial.print("type   ");  Serial.println((int)type);
#endif                    
      if(type == 255) continue;     
    if(created==true)
    {
      bfill.emit_p(PSTR(","));created=false;
    }      
      if(devicegroup ==0)// get sensor
      {        
        memcpy(&tempid,id,sizeof(id));
#ifdef DEBUG 
//Serial.print("type:");Serial.println(type);
#endif
        switch(type)
        {
          case 0:
          strcat(tempid,"0");
          break;
          
          case 1:
          strcat(tempid,"1");
          break;
          
          case 2:
          strcat(tempid,"2");
          break;
          
          case 3:
          strcat(tempid,"3");
          break;
          
          case 4:
          strcat(tempid,"4");
          break;
        }
        //http://webinos.org/api/
#ifdef DEBUG 
//Serial.println(tempid);
#endif        


        bfill.emit_p(PSTR("{\"sId\":\"$S\""), tempid); // start address from 0
        //Serial.println(id);
        strcpy_P(line_buf, (char*)pgm_read_word(&(sensor_table[type])));
        bfill.emit_p(PSTR(",\"sType\":\"$S\"}"), line_buf); // 
        created = true; 
        memset(&line_buf,0,150);
      }
      
      else if(devicegroup ==1) // get actuator
      {
        bfill.emit_p(PSTR("{\"aId\":\"$S\""), id);   // start address from 0
        strcpy_P(line_buf, (char*)pgm_read_word(&(actuator_table[type-10])));
        bfill.emit_p(PSTR(",\"aType\":\"$S\""), line_buf);   // start address from 0
      }
      /**/      
      memset(&tempid,0,15);
      

    }   
  }
  bfill.emit_p(PSTR(
        "]"));
  SRAM9.closeRWstream();
}

// http://192.168.210.203/sensors/0004A32C30231
void getInfo(byte deviceGroup, char *id)
{
  
  //Serial.println(id[12]);
  byte type = id[6]-'0';
  
  memset(&mote,NULL,sizeof(Mote));
  boolean found = false;
  SRAM9.readstream(INDEX_MOTE_LENGTH);   // start address from 0   
  
  int length = (int)SRAM9.RWdata(0xFF); // get the length of devices
  //Serial.print("len:");Serial.println((int)length);
   
  // http://192.168.210.203/motes/F6F_hum
  for(int i=0;i<length;i++)
  {  
    //Serial.print("id:");Serial.println(id);
    if(found ==true) break;    
    SRAM9.readstream(LIST_MOTE_BEGIN+i*sizeof(Mote));   // start address from 0

     // id
    memset(line_buf,0,50); 

    
    for(byte j=0;j<12;j++)
    {
      byte a = SRAM9.RWdata(0xFF);
      if(j>5)
      line_buf[j-6]= a;
     
    }
    //Serial.print(" ---- ");Serial.println(line_buf);
    if(strncmp(id,line_buf,6)==0)
    {      
      bfill = ether.tcpOffset();
      bfill.emit_p(PSTR(
        "HTTP/1.0 200 OK\r\n"
        "Content-Type: text/html\r\n"
        "Pragma: no-cache\r\n"
        "\r\n"));
      
     // Serial.print("==========================found:    ");Serial.print(id);Serial.print("   compares:  ");Serial.println(line_buf);
      /*  type    */
      for(byte j=0;j<5;j++)
      {
         byte s =  SRAM9.RWdata(0xFF);
         if(s == type)
         found = true; 
      }
      
      if(found)
      {  
          //Serial.println("//////////////////////////////////");
         /*  id    */
         if(deviceGroup ==0)
          bfill.emit_p(PSTR("{\"sId\":\"$S\""), id);
          else
          bfill.emit_p(PSTR("{\"aId\":\"$S\""), id);        
        
        
        strcpy_P(line_buf, (char*)pgm_read_word(&(sensor_table[type]))); // Necessary casts and dereferencing, just copy. 
       
#ifdef DEBUG
//Serial.println( line_buf );
#endif  
    
        if(deviceGroup ==0)
        bfill.emit_p(PSTR(",\"sType\":\"$S\""), line_buf);
        else
        bfill.emit_p(PSTR(",\"aType\":\"$S\""), line_buf);
      
        bfill.emit_p(PSTR(",\"vendor\":\"HOC\",\"version\":\"01\",\"name\":\"$S\"}"), "sensor");
       }
       
       break;
    }   
  }
  
  SRAM9.closeRWstream();
  
 
  if(!found)
  {
        http404();  
  }
/////////////////////////////////////////////////////////  
}


static char* wtoa (word value, char* ptr) {
  if (value > 9)
    ptr = wtoa(value / 10, ptr);
  *ptr = '0' + value % 10;
  *++ptr = 0;
  return ptr;
}
