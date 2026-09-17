//+------------------------------------------------------------------+
//|                                              ORB_MarketExec.mq5   |
//| Opening Range Breakout - MARKET EXECUTION ONLY                   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025-2026, Osamwonyi Eric (You_FoundEric)"
#property link      "https://t.me/You_FoundEric"
#property version   "4.00"
#property description "ORB Market Exec - market execution only"
#property description "Explicit DST-aware/fixed-EST clock, side expiry, news guard, blackout flatten."
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//====================================================================
// Enums
//====================================================================
enum ENUM_ORB_CLOCK_MODE
{
   ORB_CLOCK_NEW_YORK_WALL = 0, // Input clock follows New York wall time. 21:00 means 9pm NY year-round; UTC mapping auto-shifts for DST.
   ORB_CLOCK_FIXED_EST     = 1  // Input clock is fixed UTC-5. 21:00 never shifts for DST.
};

enum ENUM_RISK_BASIS
{
   RISK_BASIS_BALANCE = 0,
   RISK_BASIS_EQUITY  = 1,
   RISK_BASIS_MARGIN  = 2
};

enum ENUM_RR_MODE
{
   RR_OFF = 0,
   RR_0_5 = 1,
   RR_1_0 = 2,
   RR_1_5 = 3,
   RR_2_0 = 4,
   RR_2_5 = 5,
   RR_3_0 = 6,
   RR_4_0 = 7,
   RR_5_0 = 8
};

enum ENUM_NEWS_GUARD_MODE
{
   NEWS_GUARD_DISABLED   = 0,
   NEWS_GUARD_RED        = 1,
   NEWS_GUARD_RED_YELLOW = 2,
   NEWS_GUARD_ALL        = 3
};

//====================================================================
// Inputs
//====================================================================
input group "==========  1 - Session Clock  =========="
input ENUM_ORB_CLOCK_MODE Clock_Mode = ORB_CLOCK_NEW_YORK_WALL; // NY WALL = automatic DST. FIXED EST = UTC-5, never shifts.
input int    Session_Hour            = 21; // Opening-range start hour in the selected clock mode.
input int    Session_Minute          = 0;  // Opening-range start minute in the selected clock mode.
input int    Tester_Server_UTC_Offset_Hours = 0; // Strategy Tester only. Broker server offset from UTC when live clock detection is unavailable.
input bool   Inp_StealthMode         = true;

input group " "
input group "==========  2 - Range & Trigger  =========="
input bool   Allow_Buy                = true;
input bool   Allow_Sell               = false;
input double Min_Range_Points         = 0.0;
input double Max_Range_Points         = 0.0;
input double Breakout_Buffer_Points   = 0.0;
input ENUM_TIMEFRAMES Trigger_Timeframe = PERIOD_M15; // Candle close confirmation timeframe.
input int    Range_Minutes            = 15;           // Default range = 21:00-21:15.
input int    Side_Expiry_Hour         = 9;            // Untriggered side expires at this time after the range session starts.
input int    Side_Expiry_Minute       = 0;

input group "  "
input group "==========  3 - Stop Loss / Take Profit  =========="
input double       SL_Buffer_Points   = 0.0;
input ENUM_RR_MODE Take_Profit_RR     = RR_1_0;
input int Time_Exit_Hour   = 15; // -1 disables strategy-owned position time exit.
input int Time_Exit_Minute = 0;

input group "   "
input group "==========  4 - Blackout Flatten  =========="
input bool Blackout_Flatten_All_Positions = false; // At blackout time, close ALL account positions and delete ALL pending orders.
input int  Blackout_Hour                  = 8;
input int  Blackout_Minute                = 25;

input group "    "
input group "==========  5 - Risk & Position Sizing  =========="
input double          Risk_Percent            = 1.0;
input ENUM_RISK_BASIS Risk_Basis              = RISK_BASIS_BALANCE;
input double          Custom_Balance_Override = 0.0;
input double          Fixed_Lot_Size          = 0.0;
input int             Max_Slippage_Points     = 3;
input double          Max_Spread_Points       = 0.0;

input group "     "
input group "==========  6 - News Filter  =========="
input ENUM_NEWS_GUARD_MODE News_Guard_Mode = NEWS_GUARD_DISABLED;
input int    News_Block_Before_Min  = 30;
input int    News_Block_After_Min   = 15;
input bool   Inp_Holiday_Blackout   = true;

input group "      "
input group "==========  7 - Visuals  =========="
input bool   Show_Range_Box            = true;
input bool   Show_Exec_Objects         = true;
input color  Clr_Range_High            = clrDodgerBlue;
input color  Clr_Range_Low             = clrGray;
input color  Clr_Entry_Line            = clrDodgerBlue;
input color  Clr_SL_Box                = clrGray;
input color  Clr_TP_Box                = clrDodgerBlue;

input group "       "
input group "==========  8 - Misc  =========="
input int    Magic_Number              = 921100;
input string Trade_Comment             = "ORB-MktExec";
input string Obj_Prefix                = "ORBME_";

input group "        "
input group "==========  9 - Execution Cost Model  =========="
input double Commission_Per_Lot_Override = 0.0;
input double Assumed_RT_Comm_Per_Lot     = 0.0;
input int    Assumed_Slip_Points         = 3;

//====================================================================
// State
//====================================================================
string   g_sessionKey = "";
datetime g_sessionOpenServer = 0;
datetime g_rangeEndServer = 0;
datetime g_sideExpiryServer = 0;
datetime g_timeExitServer = 0;
datetime g_blackoutServer = 0;

bool     g_rangeCaptured = false;
bool     g_rangeRejected = false;
double   g_rangeHigh = 0.0;
double   g_rangeLow  = 0.0;
datetime g_lastProcessedBar = 0;
bool     g_buyConsumed = false;
bool     g_sellConsumed = false;
bool     g_blackoutDone = false;

//====================================================================
// Time helpers
//====================================================================
datetime MakeDateTime(int y,int mo,int d,int h,int mi,int s)
{
   MqlDateTime x; ZeroMemory(x);
   x.year=y; x.mon=mo; x.day=d; x.hour=h; x.min=mi; x.sec=s;
   return StructToTime(x);
}

int NthSundayOfMonthUTC(int year,int month,int nth)
{
   MqlDateTime dt; ZeroMemory(dt);
   dt.year=year; dt.mon=month; dt.day=1;
   datetime first=StructToTime(dt);
   TimeToStruct(first,dt);
   int firstSunday=1+((7-dt.day_of_week)%7);
   return firstSunday+(nth-1)*7;
}

int NewYorkUTCOffsetSec(datetime utc)
{
   MqlDateTime d; TimeToStruct(utc,d);
   int mar=NthSundayOfMonthUTC(d.year,3,2);
   int nov=NthSundayOfMonthUTC(d.year,11,1);
   datetime start=MakeDateTime(d.year,3,mar,7,0,0);
   datetime finish=MakeDateTime(d.year,11,nov,6,0,0);
   return (utc>=start && utc<finish) ? -4*3600 : -5*3600;
}

int SelectedClockUTCOffsetSec(datetime utc)
{
   if(Clock_Mode==ORB_CLOCK_FIXED_EST) return -5*3600;
   return NewYorkUTCOffsetSec(utc);
}

int ServerUTCOffsetSec()
{
   if((bool)MQLInfoInteger(MQL_TESTER))
      return Tester_Server_UTC_Offset_Hours*3600;

   datetime gmt=TimeGMT();
   datetime srv=TimeTradeServer();
   if(srv<=0) srv=TimeCurrent();
   return (int)MathRound((double)(srv-gmt)/3600.0)*3600;
}

int ServerToSelectedOffsetSec(datetime serverNow)
{
   datetime utc=serverNow-ServerUTCOffsetSec();
   return ServerUTCOffsetSec()-SelectedClockUTCOffsetSec(utc);
}

datetime ServerToSelected(datetime serverTime)
{
   return serverTime-ServerToSelectedOffsetSec(serverTime);
}

datetime SelectedToServer(int y,int mo,int d,int h,int mi,int s)
{
   datetime local=MakeDateTime(y,mo,d,h,mi,s);

   // First estimate UTC from fixed EST; then refine once for NY DST.
   int refOff=(Clock_Mode==ORB_CLOCK_FIXED_EST ? -5*3600 : -5*3600);
   datetime utc=local-refOff;
   refOff=SelectedClockUTCOffsetSec(utc);
   utc=local-refOff;
   return utc+ServerUTCOffsetSec();
}

string ClockName()
{
   return Clock_Mode==ORB_CLOCK_FIXED_EST ? "Fixed EST (UTC-5, no DST)" : "New York wall clock (DST-aware)";
}

datetime ResolveClockAfterOpen(datetime openSrv,int hour,int minute)
{
   datetime localOpen=ServerToSelected(openSrv);
   MqlDateTime d; TimeToStruct(localOpen,d);
   datetime t=SelectedToServer(d.year,d.mon,d.day,hour,minute,0);
   if(t<=openSrv)
   {
      datetime nextLocal=MakeDateTime(d.year,d.mon,d.day,0,0,0)+86400;
      MqlDateTime n; TimeToStruct(nextLocal,n);
      t=SelectedToServer(n.year,n.mon,n.day,hour,minute,0);
   }
   return t;
}

datetime GetActiveSessionOpen(datetime serverNow,string &key)
{
   datetime refNow=ServerToSelected(serverNow);
   MqlDateTime d; TimeToStruct(refNow,d);
   datetime today=MakeDateTime(d.year,d.mon,d.day,Session_Hour,Session_Minute,0);
   if(refNow<today)
   {
      datetime prev=today-86400;
      TimeToStruct(prev,d);
   }
   key=StringFormat("%04d%02d%02d",d.year,d.mon,d.day);
   return SelectedToServer(d.year,d.mon,d.day,Session_Hour,Session_Minute,0);
}

//====================================================================
// RR / risk helpers
//====================================================================
double RRValue(ENUM_RR_MODE m)
{
   switch(m)
   {
      case RR_0_5: return 0.5;
      case RR_1_0: return 1.0;
      case RR_1_5: return 1.5;
      case RR_2_0: return 2.0;
      case RR_2_5: return 2.5;
      case RR_3_0: return 3.0;
      case RR_4_0: return 4.0;
      case RR_5_0: return 5.0;
      default: return 0.0;
   }
}

double AccountBasisValue()
{
   if(Custom_Balance_Override>0) return Custom_Balance_Override;
   if(Risk_Basis==RISK_BASIS_EQUITY) return AccountInfoDouble(ACCOUNT_EQUITY);
   if(Risk_Basis==RISK_BASIS_MARGIN) return AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return AccountInfoDouble(ACCOUNT_BALANCE);
}

double CashPerLotForDistance(double dist)
{
   if(dist<=0) return 0;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   if(ask<=0) ask=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double loss=0;
   if(ask>0 && OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,1.0,ask,ask-dist,loss))
      return MathAbs(loss);

   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickVal =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize>0 && tickVal>0) return dist/tickSize*tickVal;
   return dist*SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE);
}

double CostPerLot()
{
   double comm=MathMax(Commission_Per_Lot_Override,Assumed_RT_Comm_Per_Lot);
   double slip=CashPerLotForDistance(MathMax(0,Assumed_Slip_Points)*_Point)*2.0;
   return MathMax(0,comm)+slip;
}

double CalcLots(double stopDist)
{
   if(Fixed_Lot_Size>0) return Fixed_Lot_Size;
   double budget=AccountBasisValue()*Risk_Percent/100.0;
   double perLot=CashPerLotForDistance(stopDist)+CostPerLot();
   if(perLot<=0 || budget<=0) return 0;

   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0) step=0.01;
   double lots=MathFloor((budget/perLot)/step)*step;
   if(lots<minLot) return 0;
   if(lots>maxLot) lots=MathFloor(maxLot/step)*step;
   return lots;
}

bool SpreadOK()
{
   if(Max_Spread_Points<=0) return true;
   return (double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=Max_Spread_Points;
}

//====================================================================
// News filter
//====================================================================
struct ORBNewsEvent
{
   datetime time;
   string currency;
   string name;
   int importance;
};
ORBNewsEvent g_news[];
datetime g_newsCacheClockDay=0;

bool NewsImpactAllowed(int imp)
{
   if(News_Guard_Mode==NEWS_GUARD_ALL) return true;
   if(imp==CALENDAR_IMPORTANCE_HIGH) return true;
   if(News_Guard_Mode==NEWS_GUARD_RED_YELLOW && imp==CALENDAR_IMPORTANCE_MODERATE) return true;
   return false;
}

void AddCurrency(string &a[],string c)
{
   StringToUpper(c);
   if(StringLen(c)!=3) return;
   for(int i=0;i<ArraySize(a);i++) if(a[i]==c) return;
   int n=ArraySize(a); ArrayResize(a,n+1); a[n]=c;
}

void WatchedCurrencies(string &a[])
{
   ArrayResize(a,0);
   AddCurrency(a,SymbolInfoString(_Symbol,SYMBOL_CURRENCY_BASE));
   AddCurrency(a,SymbolInfoString(_Symbol,SYMBOL_CURRENCY_PROFIT));
   AddCurrency(a,SymbolInfoString(_Symbol,SYMBOL_CURRENCY_MARGIN));
   string s=_Symbol; StringToUpper(s);
   string known[8]={"USD","EUR","GBP","JPY","AUD","CAD","CHF","NZD"};
   for(int k=0;k<8;k++) if(StringFind(s,known[k])>=0) AddCurrency(a,known[k]);
   if(ArraySize(a)==0) AddCurrency(a,"USD");
}

bool CurrencyWatched(string c,string &a[])
{
   StringToUpper(c);
   for(int i=0;i<ArraySize(a);i++) if(a[i]==c) return true;
   return false;
}

void LoadNews(datetime nowSrv)
{
   if(News_Guard_Mode==NEWS_GUARD_DISABLED) return;

   datetime ref=ServerToSelected(nowSrv);
   MqlDateTime d; TimeToStruct(ref,d);
   datetime refDay=MakeDateTime(d.year,d.mon,d.day,0,0,0);
   if(g_newsCacheClockDay==refDay) return;
   g_newsCacheClockDay=refDay;
   ArrayResize(g_news,0);

   datetime from=SelectedToServer(d.year,d.mon,d.day,0,0,0)-News_Block_After_Min*60-3600;
   datetime nextRef=refDay+86400;
   MqlDateTime n; TimeToStruct(nextRef,n);
   datetime to=SelectedToServer(n.year,n.mon,n.day,0,0,0)+News_Block_Before_Min*60+3600;

   string watch[]; WatchedCurrencies(watch);
   MqlCalendarValue values[];
   ResetLastError();
   int count=CalendarValueHistory(values,from,to,NULL,NULL);
   if(count<0)
   {
      PrintFormat("[ORB-ME NEWS] CalendarValueHistory failed. error=%d",GetLastError());
      return;
   }

   for(int i=0;i<count;i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id,ev)) continue;
      if(!NewsImpactAllowed((int)ev.importance)) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(ev.country_id,country)) continue;
      if(!CurrencyWatched(country.currency,watch)) continue;

      int z=ArraySize(g_news); ArrayResize(g_news,z+1);
      g_news[z].time=values[i].time;
      g_news[z].currency=country.currency;
      g_news[z].name=ev.name;
      g_news[z].importance=(int)ev.importance;
   }

   if(!Inp_StealthMode)
      PrintFormat("[ORB-ME NEWS] Loaded %d matching events for selected clock day %s.",ArraySize(g_news),TimeToString(refDay,TIME_DATE));
}

bool IsNewsBlocked(datetime nowSrv)
{
   if(News_Guard_Mode==NEWS_GUARD_DISABLED) return false;
   LoadNews(nowSrv);
   int before=MathMax(0,News_Block_Before_Min)*60;
   int after =MathMax(0,News_Block_After_Min)*60;
   for(int i=0;i<ArraySize(g_news);i++)
      if(nowSrv>=g_news[i].time-before && nowSrv<=g_news[i].time+after)
         return true;
   return false;
}

bool IsHoliday(datetime nowSrv)
{
   if(!Inp_Holiday_Blackout) return false;
   datetime ref=ServerToSelected(nowSrv);
   MqlDateTime d; TimeToStruct(ref,d);
   datetime from=SelectedToServer(d.year,d.mon,d.day,0,0,0)-3600;
   datetime next=MakeDateTime(d.year,d.mon,d.day,0,0,0)+86400;
   MqlDateTime n; TimeToStruct(next,n);
   datetime to=SelectedToServer(n.year,n.mon,n.day,0,0,0)+3600;

   string watch[]; WatchedCurrencies(watch);
   MqlCalendarValue values[];
   if(CalendarValueHistory(values,from,to,NULL,NULL)<=0) return false;
   for(int i=0;i<ArraySize(values);i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id,ev)) continue;
      if(ev.type!=CALENDAR_TYPE_HOLIDAY) continue;
      MqlCalendarCountry c;
      if(!CalendarCountryById(ev.country_id,c)) continue;
      if(CurrencyWatched(c.currency,watch)) return true;
   }
   return false;
}

//====================================================================
// Visuals
//====================================================================
void DeleteObjects()
{
   ObjectsDeleteAll(0,Obj_Prefix);
}

void DrawH(string name,datetime a,datetime b,double p,color c,int style,int width)
{
   if(!Show_Exec_Objects && StringFind(name,"EXEC")>=0) return;
   ObjectDelete(0,name);
   if(ObjectCreate(0,name,OBJ_TREND,0,a,p,b,p))
   {
      ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(0,name,OBJPROP_COLOR,c);
      ObjectSetInteger(0,name,OBJPROP_STYLE,style);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   }
}

void DrawRange()
{
   if(!Show_Range_Box || !g_rangeCaptured) return;
   string box=Obj_Prefix+"RANGE";
   ObjectDelete(0,box);
   if(ObjectCreate(0,box,OBJ_RECTANGLE,0,g_sessionOpenServer,g_rangeHigh,g_rangeEndServer,g_rangeLow))
   {
      ObjectSetInteger(0,box,OBJPROP_COLOR,clrGray);
      ObjectSetInteger(0,box,OBJPROP_FILL,false);
      ObjectSetInteger(0,box,OBJPROP_SELECTABLE,false);
   }
   DrawH(Obj_Prefix+"HIGH",g_sessionOpenServer,g_sideExpiryServer,g_rangeHigh,Clr_Range_High,STYLE_SOLID,2);
   DrawH(Obj_Prefix+"LOW", g_sessionOpenServer,g_sideExpiryServer,g_rangeLow, Clr_Range_Low, STYLE_SOLID,2);
}

void DrawExecution(bool buy,datetime t,double entry,double sl,double tp)
{
   if(!Show_Exec_Objects) return;
   string id=IntegerToString((int)t)+(buy?"B":"S");
   datetime edge=t+3*PeriodSeconds(Trigger_Timeframe);
   DrawH(Obj_Prefix+"EXEC_E_"+id,t,edge,entry,Clr_Entry_Line,STYLE_SOLID,2);
   DrawH(Obj_Prefix+"EXEC_S_"+id,t,edge,sl,Clr_SL_Box,STYLE_DASH,2);
   if(tp>0) DrawH(Obj_Prefix+"EXEC_T_"+id,t,edge,tp,Clr_TP_Box,STYLE_DASH,2);
}

//====================================================================
// Session / range
//====================================================================
void ResetSession(string key,datetime openSrv)
{
   g_sessionKey=key;
   g_sessionOpenServer=openSrv;
   g_rangeEndServer=openSrv+Range_Minutes*60;
   g_sideExpiryServer=ResolveClockAfterOpen(openSrv,Side_Expiry_Hour,Side_Expiry_Minute);
   g_timeExitServer=(Time_Exit_Hour<0 ? 0 : ResolveClockAfterOpen(openSrv,Time_Exit_Hour,Time_Exit_Minute));
   g_blackoutServer=(Blackout_Flatten_All_Positions ? ResolveClockAfterOpen(openSrv,Blackout_Hour,Blackout_Minute) : 0);
   g_rangeCaptured=false;
   g_rangeRejected=false;
   g_rangeHigh=0;
   g_rangeLow=0;
   g_lastProcessedBar=0;
   g_buyConsumed=false;
   g_sellConsumed=false;
   g_blackoutDone=false;
   DeleteObjects();

   if(!Inp_StealthMode)
      PrintFormat("[ORB-ME] New session %s | %s | range %02d:%02d for %dm | side expiry %02d:%02d",
                  key,ClockName(),Session_Hour,Session_Minute,Range_Minutes,Side_Expiry_Hour,Side_Expiry_Minute);
}

void TryCaptureRange()
{
   if(g_rangeCaptured || TimeCurrent()<g_rangeEndServer) return;
   int sec=PeriodSeconds(Trigger_Timeframe);
   if(sec<=0 || Range_Minutes*60%sec!=0) return;
   int bars=Range_Minutes*60/sec;

   double hi=0,lo=0;
   for(int i=0;i<bars;i++)
   {
      datetime wanted=g_sessionOpenServer+i*sec;
      int shift=iBarShift(_Symbol,Trigger_Timeframe,wanted,true);
      if(shift<0 || iTime(_Symbol,Trigger_Timeframe,shift)!=wanted) return;
      double bh=iHigh(_Symbol,Trigger_Timeframe,shift);
      double bl=iLow(_Symbol,Trigger_Timeframe,shift);
      if(i==0){hi=bh;lo=bl;} else {hi=MathMax(hi,bh);lo=MathMin(lo,bl);}
   }
   if(hi<=lo) return;

   g_rangeHigh=hi;
   g_rangeLow=lo;
   g_rangeCaptured=true;
   g_lastProcessedBar=g_rangeEndServer-sec;

   double pts=(hi-lo)/_Point;
   if(Min_Range_Points>0 && pts<Min_Range_Points) g_rangeRejected=true;
   if(Max_Range_Points>0 && pts>Max_Range_Points) g_rangeRejected=true;

   DrawRange();
   PrintFormat("[ORB-ME] Range captured %s-%s: high=%s low=%s size=%.1fpts",
               TimeToString(ServerToSelected(g_sessionOpenServer),TIME_MINUTES),
               TimeToString(ServerToSelected(g_rangeEndServer),TIME_MINUTES),
               DoubleToString(hi,_Digits),DoubleToString(lo,_Digits),pts);
}

//====================================================================
// Execution
//====================================================================
void ExecuteBreakout(bool buy,double confirmationClose,datetime barClose)
{
   if(IsHoliday(TimeCurrent()))
   {
      Print("[ORB-ME] Entry suppressed: bank holiday. Side consumed.");
      return;
   }
   if(IsNewsBlocked(TimeCurrent()))
   {
      Print("[ORB-ME] Entry suppressed: economic-news window. Side consumed.");
      return;
   }
   if(!SpreadOK())
   {
      Print("[ORB-ME] Entry suppressed: spread too wide. Side consumed.");
      return;
   }

   double market=buy ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl=buy ? g_rangeLow-SL_Buffer_Points*_Point : g_rangeHigh+SL_Buffer_Points*_Point;
   sl=NormalizeDouble(sl,_Digits);
   double dist=buy ? market-sl : sl-market;
   if(dist<=0) return;

   double lots=CalcLots(dist);
   if(lots<=0)
   {
      Print("[ORB-ME] Entry refused: risk budget cannot afford minimum lot.");
      return;
   }

   double rr=RRValue(Take_Profit_RR);
   double tp=0;
   if(rr>0) tp=NormalizeDouble(buy ? market+dist*rr : market-dist*rr,_Digits);

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(Max_Slippage_Points);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok=buy ? trade.Buy(lots,_Symbol,0,sl,tp,Trade_Comment)
               : trade.Sell(lots,_Symbol,0,sl,tp,Trade_Comment);
   if(!ok)
   {
      PrintFormat("[ORB-ME] %s failed. retcode=%d %s",buy?"BUY":"SELL",trade.ResultRetcode(),trade.ResultRetcodeDescription());
      return;
   }

   double fill=trade.ResultPrice();
   if(fill<=0) fill=market;
   DrawExecution(buy,barClose,fill,sl,tp);
   PrintFormat("[ORB-ME] %s filled @ %s | SL=%s | TP=%s | lots=%.2f",
               buy?"BUY":"SELL",DoubleToString(fill,_Digits),DoubleToString(sl,_Digits),DoubleToString(tp,_Digits),lots);
}

void CheckBreakout()
{
   if(!g_rangeCaptured || g_rangeRejected) return;
   if(TimeCurrent()>=g_sideExpiryServer) return;
   if(g_buyConsumed && g_sellConsumed) return;

   datetime bar=iTime(_Symbol,Trigger_Timeframe,1);
   if(bar<=g_lastProcessedBar || bar<g_rangeEndServer) return;
   g_lastProcessedBar=bar;

   double close=iClose(_Symbol,Trigger_Timeframe,1);
   double buf=Breakout_Buffer_Points*_Point;
   bool buy=Allow_Buy && !g_buyConsumed && close>g_rangeHigh+buf;
   bool sell=Allow_Sell && !g_sellConsumed && close<g_rangeLow-buf;
   if(buy && sell) return;

   datetime barClose=bar+PeriodSeconds(Trigger_Timeframe);
   if(barClose>g_sideExpiryServer) return;

   // First qualifying close consumes that side even if a later guard blocks execution.
   if(buy)
   {
      g_buyConsumed=true;
      ExecuteBreakout(true,close,barClose);
   }
   if(sell)
   {
      g_sellConsumed=true;
      ExecuteBreakout(false,close,barClose);
   }
}

void EnforceTimeExit()
{
   if(g_timeExitServer<=0 || TimeCurrent()<g_timeExitServer) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic_Number) continue;
      trade.PositionClose(ticket,Max_Slippage_Points);
   }
}

void FlattenEverythingAtBlackout()
{
   if(!Blackout_Flatten_All_Positions || g_blackoutDone || g_blackoutServer<=0 || TimeCurrent()<g_blackoutServer) return;
   g_blackoutDone=true;

   // Delete all pending orders on the account.
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket>0) trade.OrderDelete(ticket);
   }

   // Close all positions on the account, regardless of symbol or magic.
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0) trade.PositionClose(ticket,Max_Slippage_Points);
   }
   PrintFormat("[ORB-ME] BLACKOUT: flattened all account positions and pending orders at %s (%s).",
               TimeToString(ServerToSelected(TimeCurrent()),TIME_MINUTES),ClockName());
}

//====================================================================
// Lifecycle
//====================================================================
int OnInit()
{
   if(Session_Hour<0 || Session_Hour>23 || Session_Minute<0 || Session_Minute>59)
      return INIT_PARAMETERS_INCORRECT;
   if(Side_Expiry_Hour<0 || Side_Expiry_Hour>23 || Side_Expiry_Minute<0 || Side_Expiry_Minute>59)
      return INIT_PARAMETERS_INCORRECT;

   int sec=PeriodSeconds(Trigger_Timeframe);
   if(sec<=0 || Range_Minutes<=0 || (Range_Minutes*60)%sec!=0)
   {
      Print("[ORB-ME] INIT FAILED: Range_Minutes must be a whole multiple of Trigger_Timeframe.");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(Max_Slippage_Points);
   trade.SetTypeFillingBySymbol(_Symbol);

   string key;
   datetime open=GetActiveSessionOpen(TimeCurrent(),key);
   ResetSession(key,open);

   PrintFormat("[ORB-ME] Initialized v4.00 | Clock=%s | Input %02d:%02d means exactly that time in the selected clock | range=%dm | confirm=%s | expiry=%02d:%02d",
               ClockName(),Session_Hour,Session_Minute,Range_Minutes,EnumToString(Trigger_Timeframe),Side_Expiry_Hour,Side_Expiry_Minute);
   if(News_Guard_Mode==NEWS_GUARD_DISABLED)
      Print("[ORB-ME] News guard disabled.");
   else
      LoadNews(TimeCurrent());
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteObjects();
}

void OnTick()
{
   string key;
   datetime open=GetActiveSessionOpen(TimeCurrent(),key);
   if(key!=g_sessionKey) ResetSession(key,open);

   TryCaptureRange();
   CheckBreakout();
   EnforceTimeExit();
   FlattenEverythingAtBlackout();
}
//+------------------------------------------------------------------+
