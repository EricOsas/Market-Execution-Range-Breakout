//+------------------------------------------------------------------+
//|                                              ORB_MarketExec.mq5  |
//| Opening Range Breakout - MARKET EXECUTION ONLY                    |
//| Standalone EA (separate from ORB_Scalper, its own project folder) |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025-2026, Osamwonyi Eric (You_FoundEric)"
#property link      "https://t.me/You_FoundEric"
#property version   "3.00"
#property description "ORB Market Exec - opening-range breakout, market orders only"
#property description "Range window + trigger timeframe are independent. Flat-by-the-clock exit."
#property description "Cost-inclusive risk sizing: the configured percent is an all-in ceiling."
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| HOW THIS EA WORKS                                                  |
//|--------------------------------------------------------------------|
//| 1. At the configured NY session time (default 21:00 / 9pm) the EA   |
//|    watches the 5-minute candle that OPENS exactly then (the         |
//|    "range candle"). Once it closes, its high/low become the range.  |
//| 2. From that point until the NEXT NY session open (a full 24h       |
//|    watch), every closed 5m candle is checked:                       |
//|       - closes ABOVE the range high -> market BUY immediately       |
//|       - closes BELOW the range low  -> market SELL immediately      |
//|    Each side is independent: once the high side fires a Buy, that   |
//|    side is "consumed" for the day, but the low side can still fire  |
//|    a Sell later the same day if price comes back and breaks it      |
//|    (and vice versa). There is no OCO between the two sides.         |
//| 3. Stop loss = opposite end of the RANGE candle (range low for a    |
//|    Buy, range high for a Sell) - not the confirmation candle.       |
//| 4. Take profit is optional, expressed as a multiple of risk (0.5R / |
//|    1R / 1.5R / 2R / 2.5R / 3R), or Off for no fixed TP.              |
//| 5. Only ever sends market orders - never a pending Buy/Sell Stop.    |
//| 6. At the next NY session open, EVERYTHING from the prior day is    |
//|    forgotten (range, lines, consumed flags, synthetic trades) and   |
//|    the EA starts a fresh watch on the new range candle.             |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Enums                                                             |
//+------------------------------------------------------------------+
enum ENUM_RISK_BASIS
{
   RISK_BASIS_BALANCE = 0, // Balance
   RISK_BASIS_EQUITY  = 1, // Equity
   RISK_BASIS_MARGIN  = 2  // Free Margin
};

enum ENUM_RR_MODE
{
   RR_OFF = 0, // Off  (no fixed TP - manage manually)
   RR_0_5 = 1, // 1 : 0.5
   RR_1_0 = 2, // 1 : 1
   RR_1_5 = 3, // 1 : 1.5
   RR_2_0 = 4, // 1 : 2
   RR_2_5 = 5, // 1 : 2.5
   RR_3_0 = 6, // 1 : 3
   RR_4_0 = 7  // 1 : 4
};

enum ENUM_NEWS_GUARD_MODE
{
   NEWS_GUARD_DISABLED   = 0, // Disabled
   NEWS_GUARD_RED        = 1, // Red-folder only
   NEWS_GUARD_RED_YELLOW = 2, // Red-folder and Yellow-folder only
   NEWS_GUARD_ALL        = 3  // All (Red, Yellow, White)
};

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "==========  1 - Session (NY time)  =========="
input int    Session_Hour_NY          = 9;     // Range candle open hour   (NY time, 0-23)
input int    Session_Minute_NY        = 30;    // Range candle open minute (NY time)
input bool   Inp_UseNewYorkDST        = true;  // Auto-adjust for US NY daylight saving
input int    Inp_ServerUTCOffsetHours = 0;     // Correction nudge on top of auto-detect, hours (0 = pure auto)
input int    ORB_TESTER_DEFAULT_SERVER_UTC_H = 8; // Tester fallback server->NY offset, hours (used only if no weekend gap is in loaded history)
input bool   Inp_StealthMode          = true;  // Stealth mode (quiet EA journal - suppresses diagnostic prints)

input group " "
input group "==========  2 - Range & Trigger  =========="
input bool   Allow_Buy                = true;  // Allow long (buy) breakouts
input bool   Allow_Sell               = false; // Allow short (sell) breakouts
input double Min_Range_Points         = 0.0;   // Ignore session if range smaller than this (0 = off)
input double Max_Range_Points         = 0.0;   // Ignore session if range larger than this  (0 = off, spike filter)
input double Breakout_Buffer_Points   = 0.0;   // Extra points beyond range level required to confirm breakout
input ENUM_TIMEFRAMES Trigger_Timeframe = PERIOD_M5; // Breakout confirmation candle timeframe (range is built from these bars too)
input int    Range_Minutes            = 30;    // Opening range length in minutes (must be a whole multiple of Trigger_Timeframe)
input bool   Use_SMA20_Trend_Filter   = false; // CHECK THE TREND: close vs SMA20(20d) picks the day's direction (long above / short below)
input double Range_Max_SMA20_Ratio    = 0.0;   // Skip day if opening range > N x typical of last 20 ranges (RMS, 0 = off, video uses 1.3)

input group "  "
input group "==========  3 - Stop Loss / Take Profit  =========="
input double       SL_Buffer_Points   = 0.0;   // Extra points added beyond the range extreme for SL
input ENUM_RR_MODE Take_Profit_RR     = RR_1_0;// Take profit as a multiple of risk (Off = no fixed TP)
input int Time_Exit_Hour_NY   = 15;  // Flatten any open position at this NY hour   (-1 = no time exit)
input int Time_Exit_Minute_NY = 0;   // Flatten any open position at this NY minute

input group "   "
input group "==========  4 - Risk & Position Sizing  =========="
input double          Risk_Percent            = 1.0;  // Risk per trade (%) - ignored if Fixed_Lot_Size > 0
input ENUM_RISK_BASIS Risk_Basis              = RISK_BASIS_BALANCE; // Basis for risk calculation
input double          Custom_Balance_Override = 0.0;  // Override balance/equity used for sizing (0 = live account)
input double          Fixed_Lot_Size          = 0.0;  // Fixed lot size (0 = use risk-based sizing)
input int             Max_Slippage_Points     = 3;    // Max slippage allowed on market fill (points)
input double          Max_Spread_Points       = 0.0;   // Skip entry if current spread exceeds this (0 = off)

input group "    "
input group "==========  5 - News Filter  =========="
input ENUM_NEWS_GUARD_MODE News_Guard_Mode = NEWS_GUARD_DISABLED; // News guard impact (blocks new entries only, windowed)
input int    News_Block_Before_Min  = 30;            // Block window: N minutes BEFORE event
input int    News_Block_After_Min   = 15;            // Block window: N minutes AFTER event
input bool   Inp_Holiday_Blackout   = true;          // Block ALL real trades for the whole NY day on a bank holiday for this asset

input group "     "
input group "==========  6 - Visuals & Dashboard  =========="
input bool   Show_Dashboard            = true;         // Show on-chart status panel
input bool   Show_Range_Box            = true;         // Draw range box + level lines on chart
input bool   Show_Exec_Objects         = true;         // Draw entry/SL/TP objects for taken trades (real + synthetic)
input color  Clr_Range_High            = clrDodgerBlue;// Range-high line color
input color  Clr_Range_Low             = clrOrangeRed; // Range-low line color
input color  Clr_Entry_Line            = clrWhite;     // Executed entry line color
input color  Clr_SL_Box                = C'186,58,58'; // SL box color
input color  Clr_TP_Box                = C'58,170,110';// TP box color

input group "      "
input group "==========  7 - Misc  =========="
input int    Magic_Number              = 921100;       // Magic number for this EA's orders
input string Trade_Comment             = "ORB-MktExec";// Order comment tag
input string Obj_Prefix                = "ORBME_";     // Prefix for chart objects (kept unique to this EA)

input group "       "
input group "==========  8 - Execution Cost Model  =========="
input double Commission_Per_Lot_Override = 0.0; // Round-turn commission per lot (0 = auto-learn from closed deals)
input double Assumed_RT_Comm_Per_Lot     = 0.0; // Floor for round-turn commission per lot until history exists
input int    Assumed_Slip_Points         = 3;   // Assumed adverse slippage on EACH side (raw points)

//+------------------------------------------------------------------+
//| Globals                                                            |
//+------------------------------------------------------------------+
CTrade trade;

string   g_sessionKey        = "";
datetime g_sessionOpenServer = 0;
bool     g_historyDerived    = false;   // one-time synthetic derivation done for this session?

bool     g_rangeCaptured     = false;
double   g_rangeHigh         = 0.0;
double   g_rangeLow          = 0.0;
datetime g_rangeCandleTime   = 0;
datetime g_rangeWindowEnd    = 0;   // server time the opening-range window closes
datetime g_timeExitServer     = 0;   // server time this session must be flat (0 = disabled)
bool     g_rangeRejected     = false;
string   g_rangeRejectReason = "";

bool     g_rangeHighAnchored = false;   // true once the high side has been closed-through
bool     g_rangeLowAnchored  = false;   // true once the low  side has been closed-through
datetime g_rangeHighAnchorT  = 0;
datetime g_rangeLowAnchorT   = 0;

datetime g_lastProcessedBarTime = 0;

bool     g_tradeTakenBuy     = false;
bool     g_tradeTakenSell    = false;

string   g_statusText        = "Waiting for session";

// Synthetic-ticket id space, well clear of any real broker ticket range.
#define ORB_SYNTH_TICKET_BASE 900000000000ULL

//+------------------------------------------------------------------+
//| Virtual/retroactive trade tracking (execution objects)             |
//+------------------------------------------------------------------+
struct VTrade
{
   ulong    ticket;       // real position id, or a synthetic id (>= ORB_SYNTH_TICKET_BASE)
   bool     bull;
   bool     isSynthetic;  // true = derived, never actually sent to the broker
   double   entryPx;
   double   sl;
   double   tp;
   double   lots;         // real filled lots, or a hypothetical lots figure for synthetic trades
   datetime triggerTime;
   datetime exitTime;     // 0 = still open / unresolved
   double   exitPx;       // used for synthetic P&L math (real trades pull P&L from deal history directly)
   double   levelPx;
   datetime levelTime;
   bool     active;
};
VTrade vTrades[];

//+------------------------------------------------------------------+
//| ------------------------- NY TIME HELPERS -------------------------|
//| Ported directly from ORB_Scalper's ORB_Time.mqh, including the      |
//| Strategy Tester weekly-open anchor - the live TimeTradeServer() vs   |
//| TimeGMT() method collapses/misbehaves in the tester because both     |
//| clocks are simulated (or, on some builds, TimeTradeServer() tracks   |
//| the real wall clock while TimeGMT() is simulated - either way it     |
//| drifts tick to tick). The anchor instead reads the guaranteed        |
//| Sunday 17:00-NY weekly market open straight out of loaded history,   |
//| which is exact and constant for the whole test run.                  |
//+------------------------------------------------------------------+
datetime MakeDateTime(int year,int mon,int day,int hour,int minute,int sec)
{
   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year=year; dt.mon=mon; dt.day=day; dt.hour=hour; dt.min=minute; dt.sec=sec;
   return StructToTime(dt);
}

int NthSundayOfMonthUTC(int year,int month,int nth)
{
   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year=year; dt.mon=month; dt.day=1;
   datetime firstDay=StructToTime(dt);
   TimeToStruct(firstDay,dt);
   int firstDow=dt.day_of_week;             // 0 = Sunday
   int firstSunday=1+((7-firstDow)%7);
   return firstSunday+(nth-1)*7;
}

// NY's own UTC offset (seconds, negative) for a given UTC instant - DST aware.
int NYUTCOffsetSec(datetime utcTime)
{
   if(!Inp_UseNewYorkDST) return -5*3600;
   MqlDateTime utc;
   TimeToStruct(utcTime,utc);
   int year=utc.year;

   int marchSunday    = NthSundayOfMonthUTC(year,3,2);
   int novemberSunday = NthSundayOfMonthUTC(year,11,1);

   MqlDateTime startUtc; ZeroMemory(startUtc);
   startUtc.year=year; startUtc.mon=3;  startUtc.day=marchSunday;    startUtc.hour=7;
   MqlDateTime endUtc;   ZeroMemory(endUtc);
   endUtc.year=year;   endUtc.mon=11; endUtc.day=novemberSunday;   endUtc.hour=6;

   datetime dstStart=StructToTime(startUtc);
   datetime dstEnd  =StructToTime(endUtc);
   return (utcTime>=dstStart && utcTime<dstEnd) ? -4*3600 : -5*3600;
}

//+------------------------------------------------------------------+
//| TESTER TIME AUTO-DETECT (weekly-open anchor) - ported verbatim     |
//| from ORB_Scalper. The market week ALWAYS opens Sunday 17:00 NY     |
//| (18:00 NY on some feeds - handled below), so the first bar after   |
//| the weekend gap reveals this feed's true server->NY offset with no |
//| manual input, cached for the rest of the run.                      |
//+------------------------------------------------------------------+
int TesterWeekAnchorOffsetSec()
{
   static int  cached = -999999;
   static bool done   = false;
   if(done) return cached;

   if(iTime(_Symbol, PERIOD_H1, 1) <= 0) return -999999; // history not loaded yet - retry later

   datetime newer = 0;
   for(int i = 1; i < 500; i++)
   {
      datetime t = iTime(_Symbol, PERIOD_H1, i);
      if(t <= 0) break;
      if(newer > 0 && (newer - t) >= 40*3600)      // candidate weekend gap
      {
         datetime weekOpenServer  = newer;
         datetime weekCloseServer = t;

         MqlDateTime co; TimeToStruct(weekCloseServer, co);
         MqlDateTime op; TimeToStruct(weekOpenServer,  op);
         bool closeIsFri   = (co.day_of_week == 5);
         bool openIsSunMon = (op.day_of_week == 0 || op.day_of_week == 1);
         if(!closeIsFri || !openIsSunMon) { newer = t; continue; }

         // The market week opens 18:00 NY on this reference model (matches
         // ORB_Scalper's proven anchor). Derive the broker's server->NY
         // offset from this bar directly.
         int srvSecDay    = (int)((long)weekOpenServer % 86400);
         int nyOpenSecDay = 18*3600;
         int diff         = srvSecDay - nyOpenSecDay;
         while(diff >  12*3600) diff -= 86400;
         while(diff < -12*3600) diff += 86400;
         int off = (int)(MathRound((double)diff/3600.0)*3600.0);

         if(off < -2*3600 || off > 10*3600) { newer = t; continue; } // plausibility gate

         cached = off;
         done   = true;
         if(!Inp_StealthMode)
            PrintFormat("[ORB-ME TIME] anchor: weekendBarServer=%s srvSecDay=%d nyOpenSecDay=%d -> serverNYoffset=%dh",
                        TimeToString(weekOpenServer, TIME_DATE|TIME_MINUTES),
                        srvSecDay, nyOpenSecDay, off/3600);
         return cached;
      }
      newer = t;
   }
   done = true; // scanned all loaded history, no valid weekend gap found -> use the sentinel/default
   return cached;
}

// SERVER -> NY offset (seconds): the single source of truth for all time
// math. LIVE: derived from TimeTradeServer() vs TimeGMT(). TESTER: derived
// from the weekly-open anchor (both clocks are simulated/unreliable in the
// tester, so the live method is skipped entirely). Inp_ServerUTCOffsetHours
// is a +/- correction nudge added on top of whichever auto value is used.
int ServerNYOffsetSec()
{
   int correction = Inp_ServerUTCOffsetHours * 3600;
   int autoOff;

   if((bool)MQLInfoInteger(MQL_TESTER))
   {
      int anchored = TesterWeekAnchorOffsetSec();
      if(anchored != -999999)
         autoOff = anchored;
      else
         autoOff = ORB_TESTER_DEFAULT_SERVER_UTC_H*3600; // no weekend in loaded range - sane pinned default
      return autoOff + correction;
   }

   // LIVE: server->UTC from the live trade-server clock vs GMT, then NY's own
   // UTC offset is added on top to express it as server->NY.
   datetime serverNow = TimeCurrent();
   datetime tradeNow  = TimeTradeServer();
   datetime gmtNow    = TimeGMT();

   int currentOff = (int)(serverNow - gmtNow);
   int tradeOff   = (tradeNow > 0) ? (int)(tradeNow - gmtNow) : 0;

   int rawUTC = 0;
   if(tradeNow > 0)                   rawUTC = tradeOff;
   else if(MathAbs(currentOff) >= 60) rawUTC = currentOff;
   int serverUTC = (int)(MathRound((double)rawUTC / 3600.0) * 3600.0);

   autoOff = serverUTC - NYUTCOffsetSec(gmtNow);
   return autoOff + correction;
}

datetime ServerToNY(datetime serverTime)
{
   return serverTime - ServerNYOffsetSec();
}

datetime NYLocalToServer(int y,int mo,int d,int h,int mi,int s)
{
   return MakeDateTime(y,mo,d,h,mi,s) + ServerNYOffsetSec();
}

// One-time diagnostic so the effective time mapping is obvious from the log.
void ORBMELogTimeMapping()
{
   if(Inp_StealthMode) return;
   datetime nowSrv = TimeCurrent();
   MqlDateTime ny; TimeToStruct(ServerToNY(nowSrv), ny);
   datetime openSrv = NYLocalToServer(ny.year,ny.mon,ny.day,Session_Hour_NY,Session_Minute_NY,0);
   MqlDateTime os; TimeToStruct(openSrv, os);
   PrintFormat("[ORB-ME TIME EFFECTIVE] serverNYoffset=%dh | NY %02d:%02d -> server %02d:%02d | tester=%s",
               ServerNYOffsetSec()/3600, Session_Hour_NY, Session_Minute_NY, os.hour, os.min,
               ((bool)MQLInfoInteger(MQL_TESTER))?"yes":"no");
}

//+------------------------------------------------------------------+
//| Session open resolver - returns the server-time open of the       |
//| CURRENTLY ACTIVE (or most recently started) session, plus its key |
//+------------------------------------------------------------------+
datetime GetActiveSessionOpenServer(datetime serverTime,string &keyOut)
{
   datetime nyNow = ServerToNY(serverTime);
   MqlDateTime ny;
   TimeToStruct(nyNow,ny);

   datetime todayOpenNY = MakeDateTime(ny.year,ny.mon,ny.day,Session_Hour_NY,Session_Minute_NY,0);

   int y=ny.year, mo=ny.mon, d=ny.day;
   if(nyNow < todayOpenNY)
   {
      datetime prevDayNY = todayOpenNY - 86400;
      MqlDateTime pd;
      TimeToStruct(prevDayNY,pd);
      y=pd.year; mo=pd.mon; d=pd.day;
   }

   keyOut = StringFormat("%04d%02d%02d",y,mo,d);
   return NYLocalToServer(y,mo,d,Session_Hour_NY,Session_Minute_NY,0);
}

//+------------------------------------------------------------------+
//| LTF (chart timeframe) helpers - bar-snapped to avoid redraw storms|
//+------------------------------------------------------------------+
int LTFSeconds() { return PeriodSeconds(); }

// The timeframe whose CLOSED candles confirm a breakout and from which the
// range is assembled. Deliberately independent of the chart timeframe:
// the strategy reads a 30-minute range but triggers on 5-minute closes, so the
// two cannot be the same setting. PERIOD_CURRENT falls back to the chart so the
// enum's zero value is never a broken configuration.
ENUM_TIMEFRAMES TriggerTF()
{
   return (Trigger_Timeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : Trigger_Timeframe;
}

int TriggerSeconds() { return PeriodSeconds(TriggerTF()); }

// CHECK THE TREND: yesterday's close vs the 20-day simple moving average of
// daily closes. Above the average = long-only day, below = short-only day.
// Uses D1 bars; shift 1 is yesterday, so the answer for today's session is
// fixed at capture time and cannot flip intraday. Returns 0 when undecided
// (no history / exactly equal) - caller treats that as "no filter".
int TrendDirectionForToday()   // +1 long-only, -1 short-only, 0 none
{
   if(!Use_SMA20_Trend_Filter) return 0;
   if(Bars(_Symbol,PERIOD_D1) < 21) return 0;

   double sum = 0.0;
   for(int i=2; i<=21; i++)          // the 20 trading days before YESTERDAY
      sum += iClose(_Symbol,PERIOD_D1,i);
   double sma20 = sum/20.0;
   double prevClose = iClose(_Symbol,PERIOD_D1,1);   // yesterday's close

   if(prevClose > sma20) return +1;
   if(prevClose < sma20) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| True when there's an actual chart being watched (live trading, or  |
//| the Strategy Tester's Visual Mode). False for a plain/optimizer     |
//| backtest run, where no one can see chart objects - in that case we |
//| skip ALL drawing/dashboard work to keep the tester at full speed,   |
//| since object create/redraw churn is one of the biggest self-        |
//| inflicted slowdowns an EA can cause in a backtest.                  |
//+------------------------------------------------------------------+
bool IsVisualContext()
{
   if(!(bool)MQLInfoInteger(MQL_TESTER)) return true;       // live/demo chart
   return (bool)MQLInfoInteger(MQL_VISUAL_MODE);            // tester: only if Visual Mode is on
}

datetime RangeLiveRightEdge()
{
   int ltfSec = LTFSeconds();
   datetime now = TimeCurrent();
   datetime blockStart = (datetime)((long)now/ltfSec*ltfSec);
   return blockStart + ltfSec;
}

datetime ExecLiveRightEdge(datetime triggerTime)
{
   int ltfSec = LTFSeconds();
   datetime now = TimeCurrent();
   datetime blockStart = (datetime)((long)now/ltfSec*ltfSec);
   datetime liveEdge = blockStart + ltfSec;
   datetime minEdge  = triggerTime + (datetime)(3*ltfSec);
   return liveEdge > minEdge ? liveEdge : minEdge;
}

datetime ExecResolvedRightEdge(datetime triggerTime,datetime exitTime)
{
   int ltfSec = LTFSeconds();
   if(exitTime > 0)
   {
      datetime snap = exitTime - 1;
      datetime minEdge = triggerTime + (datetime)(3*ltfSec);
      return snap > minEdge ? snap : minEdge;
   }
   return triggerTime + (datetime)(3*ltfSec);
}

//+------------------------------------------------------------------+
//| RR helper                                                          |
//+------------------------------------------------------------------+
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
      default:     return 0.0;
   }
}

//+------------------------------------------------------------------+
//| Lot sizing                                                         |
//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
{
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;
   double norm = MathFloor((lots+1e-9)/step)*step;
   if(norm<minLot) norm=minLot;
   if(norm>maxLot) norm=maxLot;
   int stepDigits = 2;
   if(step<0.01) stepDigits=3;
   return NormalizeDouble(norm,stepDigits);
}

double AccountBasisValue()
{
   if(Custom_Balance_Override>0.0) return Custom_Balance_Override;
   switch(Risk_Basis)
   {
      case RISK_BASIS_EQUITY: return AccountInfoDouble(ACCOUNT_EQUITY);
      case RISK_BASIS_MARGIN: return AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      default:                return AccountInfoDouble(ACCOUNT_BALANCE);
   }
}

// Sizing core. The budget is passed in rather than read from inputs so the
// self-check can probe an unaffordable budget without mutating configuration.
// CONTRACT: the returned lot size, multiplied by the all-in cash cost per lot,
// never exceeds `budget`. Returns 0.0 to REFUSE - never a rounded-up minimum.
double CalcLotSizeForBudget(double riskDistancePrice, double budget)
{
   g_lastRiskBudget = budget;

   // The budget must CONTAIN execution cost: commission and expected slippage
   // sit in the denominator beside the stop distance, so the configured
   // percentage is all-in rather than "stop loss, plus whatever costs land".
   double perLot = CashPerLotForDistance(riskDistancePrice) + ORBCostCashPerLot();
   if(riskDistancePrice<=0.0 || perLot<=0.0 || budget<=0.0)
   {
      Print(StringFormat("[ORB-ME] Sizing refused: slDist=%.5f cashPerLot=%.2f budget=%.2f.",
            riskDistancePrice,perLot,budget));
      return 0.0;
   }

   double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double lim  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
   if(step<=0.0) step=0.01;
   if(lim >0.0 && lim<mx) mx=lim;

   double lots = MathFloor((budget/perLot)/step)*step;

   if(lots < mn)
   {
      Print(StringFormat("[ORB-ME] Sizing refused: budget %.2f affords %.4f lots, below broker minimum %.2f. No trade.",
            budget,budget/perLot,mn));
      return 0.0;
   }
   if(lots > mx) lots = MathFloor(mx/step)*step;

   // HARD CEILING: re-verify after rounding and clamping.
   if(lots*perLot > budget)
   {
      double capped = MathFloor((budget/perLot)/step)*step;
      lots = (capped>=mn) ? capped : 0.0;
      if(lots<=0.0)
      {
         Print(StringFormat("[ORB-ME] Sizing refused after cap: budget %.2f cannot cover minimum lot %.2f.",budget,mn));
         return 0.0;
      }
   }

   if(!Inp_StealthMode)
      Print(StringFormat("[ORB-ME] Sizing: budget=%.2f slDist=%.5f cashPerLot=%.2f lots=%.2f (actual risk %.2f)",
            budget,riskDistancePrice,perLot,lots,lots*perLot));
   return lots;
}

double CalcLotSize(double riskDistancePrice)
{
   // An explicitly configured size is a user instruction, not a risk
   // calculation - it keeps its min-lot clamp.
   if(Fixed_Lot_Size>0.0) return NormalizeVolume(Fixed_Lot_Size);
   return CalcLotSizeForBudget(riskDistancePrice, AccountBasisValue()*Risk_Percent/100.0);
}

// Broker-aware margin cap: shrinks lots if the margin cost exceeds free margin,
// using OrderCalcMargin so the broker's own logic (leverage, margin mode) is used.
// Returns 0.0 if even minLot can't be afforded - caller must consume side as synthetic.
double MarginCapLots(double lots, bool isBuy, double entry)
{
   if(lots <= 0) return 0.0;
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin <= 0) return 0.0;

   ENUM_ORDER_TYPE ot = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double marginFor1 = 0;
   if(!OrderCalcMargin(ot, _Symbol, 1.0, entry, marginFor1) || marginFor1 <= 0)
      return lots; // can't query - pass through, broker will reject if needed

   double maxAffordable = freeMargin / marginFor1;
   maxAffordable = MathFloor((maxAffordable + 1e-9) / lotStep) * lotStep;
   if(maxAffordable < minLot) return 0.0;

   double capped = MathMin(lots, maxAffordable);
   if(capped < minLot) return 0.0;
   return NormalizeVolume(capped);
}

double g_lastRiskBudget = 0.0;   // budget used by the most recent sizing call

//+------------------------------------------------------------------+
//| One-shot sizing self-check, called from OnInit. Prints            |
//| [ORB-ME] SELFCHECK FAIL on any breach of the sizing contract.     |
//+------------------------------------------------------------------+
void ORBMESelfCheckSizing()
{
   int    fails = 0;
   double mn    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double slRaw = 200.0*_Point;                       // representative stop distance
   double cost  = ORBCostCashPerLot();
   double perLot= CashPerLotForDistance(slRaw) + cost;

   // (a) cost must sit INSIDE the sizing denominator whenever a cost is configured
   if((Assumed_Slip_Points>0 || ORBCommissionRTPerLot()>0.0) && cost<=0.0)
   {
      Print("[ORB-ME] SELFCHECK FAIL: cost model configured but ORBCostCashPerLot() returned 0.");
      fails++;
   }

   // (b) the chosen lot must never risk more than the budget
   if(Fixed_Lot_Size<=0.0 && perLot>0.0)
   {
      double budget = AccountBasisValue()*Risk_Percent/100.0;
      double lots   = CalcLotSizeForBudget(slRaw,budget);
      if(lots>0.0 && lots*perLot > budget+0.01)
      {
         Print(StringFormat("[ORB-ME] SELFCHECK FAIL: lots=%.2f risks %.2f against budget %.2f.",
               lots,lots*perLot,budget));
         fails++;
      }
   }

   // (c) a budget too small for one minimum lot must REFUSE, not round up
   if(Fixed_Lot_Size<=0.0 && perLot>0.0)
   {
      double tinyBudget = mn*perLot*0.5;
      double tinyLots   = CalcLotSizeForBudget(slRaw,tinyBudget);
      if(tinyLots != 0.0)
      {
         Print(StringFormat("[ORB-ME] SELFCHECK FAIL: budget %.2f cannot afford min lot %.2f but sizer returned %.2f.",
               tinyBudget,mn,tinyLots));
         fails++;
      }
   }

   if(fails==0)
      Print("[ORB-ME] SELFCHECK PASS: sizing is cost-inclusive, capped, and refuses below minimum lot.");
}

//+------------------------------------------------------------------+
//| ==================  CASH & COST ENGINE  ==========================|
//| Ported from ORB_Scalper.mq5 - same function names so the two EAs  |
//| stay diffable.                                                     |
//+------------------------------------------------------------------+

// True cash risked by 1.0 lot over a price distance of |slRaw|, in account
// currency. Immune to a misreported SYMBOL_TRADE_TICK_VALUE:
//   1) PRIMARY: OrderCalcProfit over the exact distance - the broker computes
//      the real loss including contract size and currency conversion.
//   2) FALLBACK: max of tickValue-based and contract-size-based cash per lot,
//      so an under-reported tickValue can never inflate the lot.
double CashPerLotForDistance(double slRaw)
{
   if(slRaw <= 0.0) return 0.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double contract  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0) ask = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double loss = 0.0;
   if(ask > 0.0 && OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, ask, ask - slRaw, loss))
   {
      double cash = MathAbs(loss);
      if(cash > 0.0) return cash;
   }

   double byTick     = (tickSize > 0.0) ? (slRaw / tickSize) * tickValue : 0.0;
   double byContract = slRaw * contract;
   return MathMax(byTick, byContract);
}

// Learns the broker's own round-turn commission per lot from closed history.
// Cached for an hour: this walks up to 180 days of deals.
double ObservedCommissionPerLot()
{
   if(Commission_Per_Lot_Override > 0.0) return Commission_Per_Lot_Override;

   static datetime s_checked = 0;
   static double   s_value   = 0.0;
   datetime now = TimeCurrent();
   if(s_checked > 0 && now - s_checked < 3600) return s_value;
   s_checked = now;
   s_value = 0.0;

   datetime from = now - 180 * 86400;
   if(!HistorySelect(from, now)) return 0.0;

   double bestRoundTurn = 0.0;
   ulong  posIds[];
   double posComm[];
   double posInVol[];
   double posOutVol[];

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;

      double vol  = HistoryDealGetDouble(deal, DEAL_VOLUME);
      double comm = MathAbs(HistoryDealGetDouble(deal, DEAL_COMMISSION));
      if(vol <= 0.0 || comm <= 0.0) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      ulong pid = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      int idx = -1;
      for(int j = 0; j < ArraySize(posIds); j++)
         if(posIds[j] == pid) { idx = j; break; }
      if(idx < 0)
      {
         idx = ArraySize(posIds);
         ArrayResize(posIds, idx + 1);
         ArrayResize(posComm, idx + 1);
         ArrayResize(posInVol, idx + 1);
         ArrayResize(posOutVol, idx + 1);
         posIds[idx] = pid;
         posComm[idx] = 0.0;
         posInVol[idx] = 0.0;
         posOutVol[idx] = 0.0;
      }

      posComm[idx] += comm;
      if(entry == DEAL_ENTRY_IN  || entry == DEAL_ENTRY_INOUT) posInVol[idx]  += vol;
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY) posOutVol[idx] += vol;
   }

   double openOnlyMax = 0.0;
   for(int i = 0; i < ArraySize(posIds); i++)
   {
      if(posInVol[i] > 0.0)
         openOnlyMax = MathMax(openOnlyMax, posComm[i] / posInVol[i]);
      if(posInVol[i] > 0.0 && posOutVol[i] > 0.0)
         bestRoundTurn = MathMax(bestRoundTurn, posComm[i] / posInVol[i]);
   }

   s_value = (bestRoundTurn > 0.0) ? bestRoundTurn : openOnlyMax;
   if(!Inp_StealthMode && s_value > 0.0)
      Print(StringFormat("[ORB-ME] Commission buffer learned: %.2f account-currency per 1.0 lot round turn.", s_value));
   return s_value;
}

// Round-turn commission per lot. The manual override wins; otherwise the
// history-learned figure floored by the assumption. The floor is not a tester
// special case: a broker that charges nothing reports nothing, which is
// indistinguishable from "no history yet".
double ORBCommissionRTPerLot()
{
   if(Commission_Per_Lot_Override > 0.0) return Commission_Per_Lot_Override;
   return MathMax(ObservedCommissionPerLot(), MathMax(0.0, Assumed_RT_Comm_Per_Lot));
}

// Expected adverse slippage on ONE side, in account currency per lot.
double ORBSlipCashPerLot()
{
   double pts = MathMax(0.0, (double)Assumed_Slip_Points);
   if(pts <= 0.0) return 0.0;
   return CashPerLotForDistance(pts * _Point);
}

// Total modeled execution cost per lot: round-turn commission plus expected
// slippage both ways. Broader than commission alone, not an extra fee.
double ORBCostCashPerLot()
{
   return ORBCommissionRTPerLot() + 2.0 * ORBSlipCashPerLot();
}

double PriceDiffToMoney(double priceDiff,double lots)
{
   // Signed: callers pass a negative diff for a losing move.
   double sign = (priceDiff < 0.0) ? -1.0 : 1.0;
   return sign * CashPerLotForDistance(MathAbs(priceDiff)) * lots;
}

//+------------------------------------------------------------------+
//| ==========================  NEWS FILTER  ==========================|
//| Trimmed port of ORB_Scalper's News Engine: MQL5 economic calendar,  |
//| auto currency-watch from the traded symbol, red/red+yellow/all      |
//| impact gating. Only gates NEW entries (this EA has no pending       |
//| orders or trailing to cancel/freeze, so those extra flags from the  |
//| original don't apply here).                                        |
//+------------------------------------------------------------------+
struct ORBNewsEvent { datetime time; string description,currencies; int importance; };
ORBNewsEvent g_newsCache[];
datetime     g_newsCacheDay = 0;
bool         g_newsCacheValid = false;

bool NewsEnabled() { return (News_Guard_Mode != NEWS_GUARD_DISABLED); }

bool NewsIsIsoCurrency(const string ccy)
{
   string known[8]={"USD","EUR","GBP","JPY","AUD","CAD","CHF","NZD"};
   string c=ccy; StringToUpper(c);
   for(int i=0;i<8;i++) if(c==known[i]) return true;
   return false;
}
void NewsAddCurrency(string &out[], string ccy)
{
   StringTrimLeft(ccy); StringTrimRight(ccy); StringToUpper(ccy);
   if(!NewsIsIsoCurrency(ccy)) return;
   for(int i=0;i<ArraySize(out);i++) if(out[i]==ccy) return;
   int n=ArraySize(out); ArrayResize(out,n+1); out[n]=ccy;
}
string NewsClean(const string sym)
{
   string u=sym; StringToUpper(u); string o="";
   for(int i=0;i<StringLen(u);i++){ ushort c=StringGetCharacter(u,i); if((c>='A'&&c<='Z')||(c>='0'&&c<='9')) o+=ShortToString(c); }
   return o;
}
void NewsAutoCurrencies(string &out[])
{
   ArrayResize(out,0);
   NewsAddCurrency(out,SymbolInfoString(_Symbol,SYMBOL_CURRENCY_BASE));
   NewsAddCurrency(out,SymbolInfoString(_Symbol,SYMBOL_CURRENCY_PROFIT));
   NewsAddCurrency(out,SymbolInfoString(_Symbol,SYMBOL_CURRENCY_MARGIN));
   string s=NewsClean(_Symbol);
   for(int i=0;i<StringLen(s)-2;i++) NewsAddCurrency(out,StringSubstr(s,i,3));
   if(ArraySize(out)==0) NewsAddCurrency(out,"USD");
}
bool NewsCurrencyMatch(const string eventCcy,string &watchList[])
{
   if(ArraySize(watchList)==0) return true;
   string ev=eventCcy; StringToUpper(ev);
   for(int i=0;i<ArraySize(watchList);i++) if(ev==watchList[i]) return true;
   return false;
}
bool NewsImpactAllowed(int importance)
{
   if(News_Guard_Mode == NEWS_GUARD_DISABLED) return false;
   if(News_Guard_Mode == NEWS_GUARD_ALL) return true;
   if(importance == CALENDAR_IMPORTANCE_HIGH) return true;
   if(News_Guard_Mode == NEWS_GUARD_RED_YELLOW && importance == CALENDAR_IMPORTANCE_MODERATE) return true;
   return false;
}
void NewsLoadCache(datetime now)
{
   datetime day=now-(now%86400);
   if(g_newsCacheValid && g_newsCacheDay==day) return;
   g_newsCacheValid=true; g_newsCacheDay=day; ArrayResize(g_newsCache,0);
   if(!NewsEnabled()) return;

   int bef=News_Block_Before_Min*60, aft=News_Block_After_Min*60;
   datetime from=day-aft-3600, to=day+86400+bef+3600;
   string watchList[]; NewsAutoCurrencies(watchList);

   MqlCalendarValue vals[];
   if(CalendarValueHistory(vals,from,to,NULL,NULL)>0)
   {
      for(int i=0;i<ArraySize(vals);i++)
      {
         MqlCalendarEvent ev; if(!CalendarEventById(vals[i].event_id,ev)) continue;
         int impact=(int)ev.importance;
         if(!NewsImpactAllowed(impact)) continue;
         MqlCalendarCountry country; if(!CalendarCountryById(ev.country_id,country)) continue;
         if(!NewsCurrencyMatch(country.currency,watchList)) continue;
         int idx=ArraySize(g_newsCache); ArrayResize(g_newsCache,idx+1);
         g_newsCache[idx].time=vals[i].time;
         g_newsCache[idx].description=ev.name;
         g_newsCache[idx].currencies=country.currency;
         g_newsCache[idx].importance=impact;
      }
   }
   if(!Inp_StealthMode)
      PrintFormat("[ORB-ME NEWS] %s | guard=%d | events cached: %d",TimeToString(day,TIME_DATE),(int)News_Guard_Mode,ArraySize(g_newsCache));
}
bool IsNewsBlocked(datetime now)
{
   if(!NewsEnabled()) return false;
   static datetime lastEval=0;
   static bool cachedRes=false;
   if(now==lastEval) return cachedRes;
   NewsLoadCache(now);
   int bef=News_Block_Before_Min*60, aft=News_Block_After_Min*60;
   cachedRes=false;
   for(int i=0;i<ArraySize(g_newsCache);i++)
   {
      datetime ev=g_newsCache[i].time;
      if(now>=ev-bef && now<=ev+aft) { cachedRes=true; break; }
   }
   lastEval=now;
   return cachedRes;
}

//+------------------------------------------------------------------+
//| Bank holiday detection - distinct from the windowed news blackout  |
//| above. A holiday event (ENUM_CALENDAR_EVENT_TYPE == CALENDAR_EVENT |
//| _TYPE_HOLIDAY) for this asset's own country blacks out the ENTIRE  |
//| NY calendar day, not just a window: no real trade fires that day.  |
//| The range still forms and is still watched/derived as synthetic -  |
//| only the actual broker order is suppressed. Cached once per NY day.|
//+------------------------------------------------------------------+
datetime g_holidayCacheDay   = 0;
bool     g_holidayCacheValid = false;
bool     g_holidayCacheIsHol = false;
string   g_holidayCacheDesc  = "";

bool IsBankHolidayToday(datetime now)
{
   if(!Inp_Holiday_Blackout) return false;

   MqlDateTime nd; TimeToStruct(ServerToNY(now),nd);
   datetime nyDayKey = MakeDateTime(nd.year,nd.mon,nd.day,0,0,0);
   if(g_holidayCacheValid && g_holidayCacheDay==nyDayKey) return g_holidayCacheIsHol;

   g_holidayCacheDay=nyDayKey; g_holidayCacheValid=true; g_holidayCacheIsHol=false; g_holidayCacheDesc="";

   datetime fromSrv = NYLocalToServer(nd.year,nd.mon,nd.day,0,0,0) - 3600;
   datetime toSrv    = fromSrv + 86400 + 7200;

   string watchList[]; NewsAutoCurrencies(watchList);
   MqlCalendarValue vals[];
   if(CalendarValueHistory(vals,fromSrv,toSrv,NULL,NULL)>0)
   {
      for(int i=0;i<ArraySize(vals);i++)
      {
         MqlCalendarEvent ev; if(!CalendarEventById(vals[i].event_id,ev)) continue;
         if(ev.type!=CALENDAR_TYPE_HOLIDAY) continue;
         MqlCalendarCountry country; if(!CalendarCountryById(ev.country_id,country)) continue;
         if(!NewsCurrencyMatch(country.currency,watchList)) continue;

         MqlDateTime hd; TimeToStruct(ServerToNY(vals[i].time),hd);
         if(hd.year==nd.year && hd.mon==nd.mon && hd.day==nd.day)
         {
            g_holidayCacheIsHol=true;
            g_holidayCacheDesc=ev.name+" ("+country.currency+")";
            break;
         }
      }
   }
   if(!Inp_StealthMode && g_holidayCacheIsHol)
      PrintFormat("[ORB-ME HOLIDAY] %s is a bank holiday for this asset: %s - range will be monitored/derived only, no real trades today.",
                  TimeToString(nyDayKey,TIME_DATE), g_holidayCacheDesc);
   return g_holidayCacheIsHol;
}

//+------------------------------------------------------------------+
//| Low-level object setters (write-through guarded)                   |
//+------------------------------------------------------------------+
void _SetI(string n,ENUM_OBJECT_PROPERTY_INTEGER p,int mod,long v)
{
   if(ObjectFind(0,n)<0) return;
   if(ObjectGetInteger(0,n,p,mod)==v) return;
   ObjectSetInteger(0,n,p,mod,v);
}
void _SetD(string n,ENUM_OBJECT_PROPERTY_DOUBLE p,int mod,double v)
{
   if(ObjectFind(0,n)<0) return;
   if(ObjectGetDouble(0,n,p,mod)==v) return;
   ObjectSetDouble(0,n,p,mod,v);
}

void DeleteObj(string name)
{
   if(ObjectFind(0,name)>=0) ObjectDelete(0,name);
}

//+------------------------------------------------------------------+
//| Range box (the initial 5m range candle itself - fixed, no stretch) |
//+------------------------------------------------------------------+
void DrawRangeCandleBox()
{
   if(!IsVisualContext()) return;
   if(!Show_Range_Box || !g_rangeCaptured) return;
   string name = Obj_Prefix+"BOX";
   datetime t1 = g_rangeCandleTime;
   datetime t2 = g_rangeWindowEnd;

   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_RECTANGLE,0,t1,g_rangeHigh,t2,g_rangeLow);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      ObjectSetInteger(0,name,OBJPROP_FILL,true);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrDimGray);
   }
}

//+------------------------------------------------------------------+
//| Range HIGH/LOW lines - live (follow price, +1 chart candle ahead) |
//| until closed through, then permanently anchored to (breakout      |
//| candle close - 1 second). Called every tick.                      |
//+------------------------------------------------------------------+
void DrawHLine(string name,datetime t1,datetime t2,double price,color clr,int style,int width)
{
   if(price<=0 || t2<=t1) return;
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_TREND,0,t1,price,t2,price);
      ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(0,name,OBJPROP_RAY_LEFT,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,name,OBJPROP_STYLE,style);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
   }
   _SetI(name,OBJPROP_TIME,0,(long)t1);
   _SetD(name,OBJPROP_PRICE,0,price);
   _SetI(name,OBJPROP_TIME,1,(long)t2);
   _SetD(name,OBJPROP_PRICE,1,price);
}

void UpdateRangeLevelLines()
{
   if(!IsVisualContext()) return;
   if(!Show_Range_Box || !g_rangeCaptured || g_rangeRejected) return;

   datetime liveEdge = RangeLiveRightEdge();
   int ltfSec = LTFSeconds();

   datetime highRight = g_rangeHighAnchored ? g_rangeHighAnchorT : liveEdge;
   if(highRight <= g_rangeCandleTime) highRight = g_rangeCandleTime + ltfSec;
   int highStyle = g_rangeHighAnchored ? STYLE_SOLID : STYLE_DASH;
   DrawHLine(Obj_Prefix+"HIGH",g_rangeCandleTime,highRight,g_rangeHigh,Clr_Range_High,highStyle,1);

   datetime lowRight = g_rangeLowAnchored ? g_rangeLowAnchorT : liveEdge;
   if(lowRight <= g_rangeCandleTime) lowRight = g_rangeCandleTime + ltfSec;
   int lowStyle = g_rangeLowAnchored ? STYLE_SOLID : STYLE_DASH;
   DrawHLine(Obj_Prefix+"LOW",g_rangeCandleTime,lowRight,g_rangeLow,Clr_Range_Low,lowStyle,1);
}

//+------------------------------------------------------------------+
//| Execution objects - entry line + SL/TP boxes, retroactive &        |
//| broker-resolved / synthetic-resolved                                |
//+------------------------------------------------------------------+
void DrawBorderBox(string name,datetime t1,datetime t2,double priceA,double priceB,color clr,int width,int style)
{
   if(t2<=t1) return;
   if(MathAbs(priceA-priceB)<=_Point*0.1) return;
   double top=MathMax(priceA,priceB), bot=MathMin(priceA,priceB);

   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_RECTANGLE,0,t1,top,t2,bot);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      ObjectSetInteger(0,name,OBJPROP_FILL,false);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
      ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   }
   _SetI(name,OBJPROP_TIME,0,(long)t1);
   _SetD(name,OBJPROP_PRICE,0,top);
   _SetI(name,OBJPROP_TIME,1,(long)t2);
   _SetD(name,OBJPROP_PRICE,1,bot);
}

void DrawTradeObjects(int i)
{
   if(!Show_Exec_Objects) return;
   string ts = (vTrades[i].isSynthetic?"SYN_":"") + IntegerToString(vTrades[i].ticket);

   bool resolved = (vTrades[i].exitTime > 0);
   datetime rightEdge = resolved
      ? ExecResolvedRightEdge(vTrades[i].triggerTime,vTrades[i].exitTime)
      : ExecLiveRightEdge(vTrades[i].triggerTime);
   if(rightEdge<=vTrades[i].triggerTime) rightEdge=vTrades[i].triggerTime+LTFSeconds();

   int entStyle = vTrades[i].isSynthetic ? STYLE_DASH : STYLE_SOLID;
   DrawHLine(Obj_Prefix+"ENT_"+ts,vTrades[i].triggerTime,rightEdge,vTrades[i].entryPx,Clr_Entry_Line,entStyle,2);

   int boxStyle = vTrades[i].isSynthetic ? STYLE_DASH : STYLE_SOLID;
   if(vTrades[i].sl>0)
      DrawBorderBox(Obj_Prefix+"SL_"+ts,vTrades[i].triggerTime,rightEdge,vTrades[i].entryPx,vTrades[i].sl,Clr_SL_Box,2,boxStyle);
   if(vTrades[i].tp>0)
      DrawBorderBox(Obj_Prefix+"TP_"+ts,vTrades[i].triggerTime,rightEdge,vTrades[i].entryPx,vTrades[i].tp,Clr_TP_Box,2,boxStyle);
}

void DeleteEAObjects()
{
   ObjectsDeleteAll(0,Obj_Prefix);
}

void DrawAllTradeObjects()
{
   if(!IsVisualContext()) return;
   if(!Show_Exec_Objects) return;
   for(int i=0;i<ArraySize(vTrades);i++)
      DrawTradeObjects(i);
}

//+------------------------------------------------------------------+
//| Retroactive trade tracking - real broker fills                    |
//+------------------------------------------------------------------+
int FindVTrade(ulong ticket)
{
   for(int i=0;i<ArraySize(vTrades);i++)
      if(vTrades[i].ticket==ticket) return i;
   return -1;
}

int RegisterVTrade(ulong ticket,bool bull,bool isSynth,double entryPx,double sl,double tp,double lots,
                    datetime triggerTime,datetime exitTime,double exitPx,double levelPx,datetime levelTime)
{
   if(FindVTrade(ticket)>=0) return FindVTrade(ticket);
   int n=ArraySize(vTrades);
   ArrayResize(vTrades,n+1);
   vTrades[n].ticket=ticket;
   vTrades[n].bull=bull;
   vTrades[n].isSynthetic=isSynth;
   vTrades[n].entryPx=entryPx;
   vTrades[n].sl=sl;
   vTrades[n].tp=tp;
   vTrades[n].lots=lots;
   vTrades[n].triggerTime=triggerTime;
   vTrades[n].exitTime=exitTime;
   vTrades[n].exitPx=exitPx;
   vTrades[n].levelPx=levelPx;
   vTrades[n].levelTime=levelTime;
   vTrades[n].active=(exitTime==0);
   return n;
}

// Scans broker deal history for THIS symbol+magic from the current session's
// open onward and rebuilds the REAL (broker-executed) side of vTrades[], so
// exec objects reappear after a restart. Cheap: bounded to the current
// session window only - nothing from a prior day is ever pulled in.
void RebuildRealTradesFromHistory()
{
   if(g_sessionOpenServer<=0) return;
   if(!HistorySelect(g_sessionOpenServer,TimeCurrent())) return;

   int deals = HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal==0) continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
      if((long)HistoryDealGetInteger(deal,DEAL_MAGIC)!=Magic_Number) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_IN) continue;

      ulong posId = (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      if(posId==0 || FindVTrade(posId)>=0) continue;

      bool bull = (HistoryDealGetInteger(deal,DEAL_TYPE)==DEAL_TYPE_BUY);
      double entryPx = HistoryDealGetDouble(deal,DEAL_PRICE);
      double lots    = HistoryDealGetDouble(deal,DEAL_VOLUME);
      datetime triggerTime = (datetime)HistoryDealGetInteger(deal,DEAL_TIME);
      double sl = HistoryDealGetDouble(deal,DEAL_SL);
      double tp = HistoryDealGetDouble(deal,DEAL_TP);

      datetime exitTime = 0;
      double   exitPx   = 0;
      if(!PositionSelectByTicket(posId))
      {
         for(int d=0; d<deals; d++)
         {
            ulong cd = HistoryDealGetTicket(d);
            if(cd==0) continue;
            if((ulong)HistoryDealGetInteger(cd,DEAL_POSITION_ID)!=posId) continue;
            if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(cd,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
            exitTime = (datetime)HistoryDealGetInteger(cd,DEAL_TIME);
            exitPx   = HistoryDealGetDouble(cd,DEAL_PRICE);
            break;
         }
      }
      int idx = RegisterVTrade(posId,bull,false,entryPx,sl,tp,lots,triggerTime,exitTime,exitPx,0.0,0);

      // A real fill consumes its side and anchors the matching level line.
      if(bull) { g_tradeTakenBuy=true;  if(!g_rangeHighAnchored){g_rangeHighAnchored=true; g_rangeHighAnchorT=triggerTime-1;} }
      else     { g_tradeTakenSell=true; if(!g_rangeLowAnchored){ g_rangeLowAnchored=true;  g_rangeLowAnchorT =triggerTime-1;} }
   }
}

// Each tick: for still-open REAL trades, check whether the broker has closed
// the position; if so, resolve the exit from the actual closing deal.
void UpdateRealOpenTrades()
{
   for(int i=0;i<ArraySize(vTrades);i++)
   {
      if(vTrades[i].isSynthetic) continue;
      if(vTrades[i].exitTime>0) continue;
      if(PositionSelectByTicket(vTrades[i].ticket)) continue; // still open

      if(HistorySelectByPosition(vTrades[i].ticket))
      {
         int nd = HistoryDealsTotal();
         for(int d=0; d<nd; d++)
         {
            ulong cd = HistoryDealGetTicket(d);
            if(cd==0) continue;
            if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(cd,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
            vTrades[i].exitTime=(datetime)HistoryDealGetInteger(cd,DEAL_TIME);
            vTrades[i].exitPx  =HistoryDealGetDouble(cd,DEAL_PRICE);
            break;
         }
      }
      if(vTrades[i].exitTime==0) vTrades[i].exitTime=TimeCurrent();
      vTrades[i].active=false;
   }
}

//+------------------------------------------------------------------+
//| ================  ONE-TIME SYNTHETIC DERIVATION  ==================|
//| Runs exactly once per EA launch (from OnInit), for the CURRENT      |
//| session only. Replays M5 bars from the range candle forward to      |
//| "now" to find any breakout that the EA did not (or could not) place |
//| a real order for, then walks forward again to see whether price     |
//| would have hit that hypothetical trade's SL or TP by now. This is a |
//| single bounded pass (at most ~288 5m bars for a 24h session) - it    |
//| never repeats on every tick.                                        |
//+------------------------------------------------------------------+
void DeriveSyntheticHistory()
{
   if(!g_rangeCaptured || g_rangeRejected) return;

   // Walk forward from the bar right after the range window.
   // exact=false so a gap at the window boundary still yields a usable anchor;
   // the per-bar time guard below is what actually enforces "after the range".
   int startShift = iBarShift(_Symbol,TriggerTF(),g_rangeWindowEnd,false);
   if(startShift<0) return;

   for(int shift=startShift; shift>=1; shift--) // walk oldest->newest (iBarShift index counts back from "now")
   {
      datetime bTime = iTime(_Symbol,TriggerTF(),shift);
      if(bTime < g_rangeWindowEnd) continue;
      if(bTime<=g_lastProcessedBarTime && g_lastProcessedBarTime>g_rangeCandleTime)
      {
         // Already covered by live processing (shouldn't normally happen on
         // first init, but guards against double counting on a hot restart).
      }

      double c = iClose(_Symbol,TriggerTF(),shift);
      double buf = Breakout_Buffer_Points*_Point;

      bool bar_wantBuy  = Allow_Buy  && !g_tradeTakenBuy  && (c > g_rangeHigh + buf);
      bool bar_wantSell = Allow_Sell && !g_tradeTakenSell && (c < g_rangeLow  - buf);
      if(bar_wantBuy && bar_wantSell) continue; // ambiguous candle, same rule as live logic

      if(!bar_wantBuy && !bar_wantSell) continue;

      bool isBuy = bar_wantBuy;
      datetime barCloseTime = bTime + TriggerSeconds();

      double sl = isBuy ? (g_rangeLow  - SL_Buffer_Points*_Point) : (g_rangeHigh + SL_Buffer_Points*_Point);
      double entryPx = c; // best available proxy for a market fill at this candle's close
      double riskDist = isBuy ? (entryPx-sl) : (sl-entryPx);
      if(riskDist<=0) continue;

      double rr = RRValue(Take_Profit_RR);
      double tp = 0;
      if(rr>0) tp = isBuy ? (entryPx+riskDist*rr) : (entryPx-riskDist*rr);

      double lots = CalcLotSize(riskDist);
      lots = MarginCapLots(lots, isBuy, entryPx); // cap to what broker would have allowed

      // Resolve forward: did SL or TP get touched by a later bar's high/low?
      datetime exitTime=0; double exitPx=0;
      for(int f=shift-1; f>=0; f--)
      {
         if(g_timeExitServer>0 && iTime(_Symbol,TriggerTF(),f)>=g_timeExitServer)
         { exitTime=g_timeExitServer; exitPx=iOpen(_Symbol,TriggerTF(),f); break; }
         double fh=iHigh(_Symbol,TriggerTF(),f), fl=iLow(_Symbol,TriggerTF(),f);
         bool slHit = isBuy ? (fl<=sl) : (fh>=sl);
         bool tpHit = (tp>0) && (isBuy ? (fh>=tp) : (fl<=tp));
         if(slHit && tpHit)
         {
            // Same candle touched both - assume the worse outcome (SL) since
            // intrabar sequence is unknown from OHLC alone (conservative).
            exitTime=iTime(_Symbol,TriggerTF(),f)+TriggerSeconds(); exitPx=sl; break;
         }
         if(slHit) { exitTime=iTime(_Symbol,TriggerTF(),f)+TriggerSeconds(); exitPx=sl; break; }
         if(tpHit) { exitTime=iTime(_Symbol,TriggerTF(),f)+TriggerSeconds(); exitPx=tp; break; }
      }

      ulong synthId = ORB_SYNTH_TICKET_BASE + (ulong)ArraySize(vTrades);
      RegisterVTrade(synthId,isBuy,true,entryPx,sl,tp,lots,barCloseTime,exitTime,exitPx,
                     isBuy?g_rangeHigh:g_rangeLow,g_rangeCandleTime);

      if(isBuy) { g_tradeTakenBuy=true;  if(!g_rangeHighAnchored){g_rangeHighAnchored=true; g_rangeHighAnchorT=barCloseTime-1;} }
      else      { g_tradeTakenSell=true; if(!g_rangeLowAnchored){ g_rangeLowAnchorT=barCloseTime-1; g_rangeLowAnchored=true;} }

      if(!Inp_StealthMode)
         Print(StringFormat("[ORB-ME SYNTH] Derived %s @ %s (no broker fill found) -> %s",
               isBuy?"BUY":"SELL",DoubleToString(entryPx,_Digits),
               exitTime>0?StringFormat("resolved @ %s",DoubleToString(exitPx,_Digits)):"still open"));
   }
}

// Each tick: cheap live tracking for still-open SYNTHETIC trades only
// (no historical rescan - just compares current price to sl/tp).
void UpdateSyntheticOpenTrades()
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   for(int i=0;i<ArraySize(vTrades);i++)
   {
      if(!vTrades[i].isSynthetic) continue;
      if(vTrades[i].exitTime>0) continue;
      bool isBuy=vTrades[i].bull;
      double px = isBuy?bid:ask;
      bool slHit = isBuy ? (px<=vTrades[i].sl) : (px>=vTrades[i].sl);
      bool tpHit = (vTrades[i].tp>0) && (isBuy ? (px>=vTrades[i].tp) : (px<=vTrades[i].tp));
      if(slHit) { vTrades[i].exitTime=TimeCurrent(); vTrades[i].exitPx=vTrades[i].sl; vTrades[i].active=false; }
      else if(tpHit) { vTrades[i].exitTime=TimeCurrent(); vTrades[i].exitPx=vTrades[i].tp; vTrades[i].active=false; }
      else if(g_timeExitServer>0 && TimeCurrent()>=g_timeExitServer)
      { vTrades[i].exitTime=TimeCurrent(); vTrades[i].exitPx=px; vTrades[i].active=false; }
   }
}

//+------------------------------------------------------------------+
//| Daily P&L - broker-realized (from deal history) + synthetic        |
//| estimate (from derived trades). Throttled - not recomputed every   |
//| single tick.                                                        |
//+------------------------------------------------------------------+
double g_cachedRealPnl=0, g_cachedSynthPnl=0;
datetime g_pnlCacheAt=0;
int g_cachedRealCount=0, g_cachedSynthCount=0, g_cachedRealWins=0, g_cachedSynthWins=0;

void UpdateDailyPnlCache()
{
   if(TimeCurrent()-g_pnlCacheAt<3 && g_pnlCacheAt>0) return; // throttle to once per ~3s
   g_pnlCacheAt=TimeCurrent();

   double realPnl=0; int realCount=0, realWins=0;
   if(g_sessionOpenServer>0 && HistorySelect(g_sessionOpenServer,TimeCurrent()))
   {
      int deals=HistoryDealsTotal();
      for(int i=0;i<deals;i++)
      {
         ulong d=HistoryDealGetTicket(i);
         if(d==0) continue;
         if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
         if((long)HistoryDealGetInteger(d,DEAL_MAGIC)!=Magic_Number) continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
         double p = HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_SWAP);
         realPnl+=p; realCount++; if(p>0) realWins++;
      }
   }

   double synthPnl=0; int synthCount=0, synthWins=0;
   for(int i=0;i<ArraySize(vTrades);i++)
   {
      if(!vTrades[i].isSynthetic || vTrades[i].exitTime==0) continue;
      double diff = vTrades[i].bull ? (vTrades[i].exitPx-vTrades[i].entryPx) : (vTrades[i].entryPx-vTrades[i].exitPx);
      double p = PriceDiffToMoney(diff,vTrades[i].lots);
      synthPnl+=p; synthCount++; if(p>0) synthWins++;
   }

   g_cachedRealPnl=realPnl; g_cachedRealCount=realCount; g_cachedRealWins=realWins;
   g_cachedSynthPnl=synthPnl; g_cachedSynthCount=synthCount; g_cachedSynthWins=synthWins;
}

//+------------------------------------------------------------------+
//| Dashboard panel (objects-based). Fixed: explicit ZORDER so the     |
//| background/header rectangles reliably sit under the text, and an   |
//| explicit ChartRedraw() each tick so label/rect changes are actually |
//| flushed to the screen instead of waiting for the next natural       |
//| chart redraw (this was the cause of the "frozen"/stuttering clock). |
//+------------------------------------------------------------------+
#define MEDB_W    300
#define MEDB_HDRH 26
#define MEDB_ROWH 16
#define MEDB_ROWS 13
#define MEDB_X    20
#define MEDB_Y    20

color DbBg()     { return C'14,18,26';   }
color DbPanel()  { return C'24,31,44';   }
color DbBorder() { return C'52,68,92';   }
color DbText()   { return C'230,238,252';}
color DbMuted()  { return C'140,158,185';}
color DbAccent() { return C'120,175,235';}
color DbGood()   { return C'120,210,150';}
color DbBad()    { return C'220,110,110';}

void DbRect(string name,int x,int y,int w,int h,color bg,color border,long zorder)
{
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,zorder);
}

void DbLabel(string name,int x,int y,string text,int fs,color clr,long zorder,string font="Segoe UI")
{
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetString(0,name,OBJPROP_FONT,font);
   }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,zorder);
   if(ObjectGetString(0,name,OBJPROP_TEXT)!=text) ObjectSetString(0,name,OBJPROP_TEXT,text);
}

void UpdateDashboard()
{
   string P = "ORBMEDB_";
   if(!IsVisualContext())
   {
      static bool clearedOnce = false;
      if(!clearedOnce) { ObjectsDeleteAll(0,P); clearedOnce = true; }
      return;
   }
   if(!Show_Dashboard) { ObjectsDeleteAll(0,P); return; }

   // Throttle: the displayed clock only has 1-second resolution anyway, so
   // rebuilding/rewriting every object property on every single tick (which
   // can be many times per second on a fast symbol, or millions of times
   // across a multi-year backtest) buys nothing but redraw overhead.
   static datetime lastDashSec = 0;
   datetime nowSrv0 = TimeCurrent();
   if(nowSrv0==lastDashSec) return;
   lastDashSec = nowSrv0;

   UpdateDailyPnlCache();

   int X=MEDB_X, Y=MEDB_Y;
   int bodyH = MEDB_HDRH + MEDB_ROWH*MEDB_ROWS + 10;

   DbRect(P+"BG",X,Y,MEDB_W,bodyH,DbPanel(),DbBorder(),0);
   DbRect(P+"HDR",X,Y,MEDB_W,MEDB_HDRH,DbBg(),DbBorder(),1);
   DbLabel(P+"TITLE",X+10,Y+6,"ORB MARKET EXEC",9,DbAccent(),2,"Segoe UI Semibold");

   datetime nowSrv = nowSrv0;
   MqlDateTime nyNow; TimeToStruct(ServerToNY(nowSrv),nyNow);

   int rowY = Y+MEDB_HDRH+8;
   int rowX = X+10;
   long z=2;

   DbLabel(P+"R1",rowX,rowY,StringFormat("NY time     %02d:%02d:%02d  %s",nyNow.hour,nyNow.min,nyNow.sec,
           ((bool)MQLInfoInteger(MQL_TESTER))?"[tester]":""),8,DbText(),z); rowY+=MEDB_ROWH;
   DbLabel(P+"R2",rowX,rowY,StringFormat("Session     %s  (open %02d:%02d NY)",g_sessionKey,Session_Hour_NY,Session_Minute_NY),8,DbMuted(),z); rowY+=MEDB_ROWH;

   if(!g_rangeCaptured)
   {
      DbLabel(P+"R3",rowX,rowY,"Range       waiting for range candle",8,DbMuted(),z); rowY+=MEDB_ROWH;
      DbLabel(P+"R4",rowX,rowY,"",8,DbMuted(),z); rowY+=MEDB_ROWH;
      DbLabel(P+"R5",rowX,rowY,"",8,DbMuted(),z); rowY+=MEDB_ROWH;
   }
   else if(g_rangeRejected)
   {
      DbLabel(P+"R3",rowX,rowY,"Range       REJECTED - "+g_rangeRejectReason,8,DbBad(),z); rowY+=MEDB_ROWH;
      DbLabel(P+"R4",rowX,rowY,StringFormat("High/Low    %s / %s",DoubleToString(g_rangeHigh,_Digits),DoubleToString(g_rangeLow,_Digits)),8,DbMuted(),z); rowY+=MEDB_ROWH;
      DbLabel(P+"R5",rowX,rowY,"",8,DbMuted(),z); rowY+=MEDB_ROWH;
   }
   else
   {
      DbLabel(P+"R3",rowX,rowY,StringFormat("Range High  %s  %s",DoubleToString(g_rangeHigh,_Digits),g_rangeHighAnchored?"[CLOSED THROUGH]":"[live]"),8,DbText(),z); rowY+=MEDB_ROWH;
      DbLabel(P+"R4",rowX,rowY,StringFormat("Range Low   %s  %s",DoubleToString(g_rangeLow,_Digits),g_rangeLowAnchored?"[CLOSED THROUGH]":"[live]"),8,DbText(),z); rowY+=MEDB_ROWH;
      DbLabel(P+"R5",rowX,rowY,StringFormat("Range size  %.1f pts",(g_rangeHigh-g_rangeLow)/_Point),8,DbMuted(),z); rowY+=MEDB_ROWH;
   }

   DbLabel(P+"R6",rowX,rowY,StringFormat("Buy side    %s",g_tradeTakenBuy?"CONSUMED":(Allow_Buy?"armed":"disabled")),8,g_tradeTakenBuy?DbGood():DbMuted(),z); rowY+=MEDB_ROWH;
   DbLabel(P+"R7",rowX,rowY,StringFormat("Sell side   %s",g_tradeTakenSell?"CONSUMED":(Allow_Sell?"armed":"disabled")),8,g_tradeTakenSell?DbGood():DbMuted(),z); rowY+=MEDB_ROWH;

   int openCount=0, realCount=0, synthCount=0;
   for(int i=0;i<ArraySize(vTrades);i++) { if(vTrades[i].active) openCount++; if(vTrades[i].isSynthetic) synthCount++; else realCount++; }
   DbLabel(P+"R8",rowX,rowY,StringFormat("Trades      %d real, %d synthetic (%d open)",realCount,synthCount,openCount),8,DbMuted(),z); rowY+=MEDB_ROWH;

   double totalPnl = g_cachedRealPnl+g_cachedSynthPnl;
   DbLabel(P+"R9",rowX,rowY,StringFormat("Realized    %s$%.2f  (%d trades)",g_cachedRealPnl>=0?"+":"-",MathAbs(g_cachedRealPnl),g_cachedRealCount),8,g_cachedRealPnl>=0?DbGood():DbBad(),z); rowY+=MEDB_ROWH;
   DbLabel(P+"R10",rowX,rowY,StringFormat("Synthetic   %s$%.2f est. (%d trades)",g_cachedSynthPnl>=0?"+":"-",MathAbs(g_cachedSynthPnl),g_cachedSynthCount),8,g_cachedSynthPnl>=0?DbGood():DbBad(),z); rowY+=MEDB_ROWH;
   DbLabel(P+"R11",rowX,rowY,StringFormat("Day total   %s$%.2f  (incl. synthetic est.)",totalPnl>=0?"+":"-",MathAbs(totalPnl)),8,totalPnl>=0?DbGood():DbBad(),z); rowY+=MEDB_ROWH;

   datetime nextOpen = g_sessionOpenServer + 86400;
   int secsLeft = (int)(nextOpen - nowSrv);
   if(secsLeft<0) secsLeft=0;
   DbLabel(P+"R12",rowX,rowY,StringFormat("Next open   %02d:%02d:%02d   News: %s",secsLeft/3600,(secsLeft%3600)/60,secsLeft%60,
           IsNewsBlocked(nowSrv)?"BLOCKED":(NewsEnabled()?"clear":"off")),8,IsNewsBlocked(nowSrv)?DbBad():DbMuted(),z); rowY+=MEDB_ROWH;

   bool isHol = IsBankHolidayToday(nowSrv);
   DbLabel(P+"R13",rowX,rowY,isHol?StringFormat("Holiday     YES - %s  (no real trades today)",g_holidayCacheDesc)
                                  :"Holiday     no  (real trades allowed)",8,isHol?DbBad():DbMuted(),z);

   // Throttled redraw too: once the objects are updated, only actually flush
   // pixels to screen a few times a second at most (chart auto-redraws on
   // its own timer besides). Skipped entirely in a non-visual backtest via
   // the OnTick-level guard below, so this only ever runs live/visual-tester.
   static datetime lastRedraw = 0;
   if(nowSrv0 - lastRedraw >= 1 || lastRedraw==0)
   {
      ChartRedraw(0);
      lastRedraw = nowSrv0;
   }
}

void DeleteDashboard()
{
   ObjectsDeleteAll(0,"ORBMEDB_");
}

//+------------------------------------------------------------------+
//| Registers a synthetic trade for a breakout that WAS confirmed (a   |
//| candle closed beyond the range) but where a real broker order was  |
//| deliberately withheld - currently only the bank-holiday blackout.  |
//| This both consumes the side (matches "that day should have no      |
//| trades") and gives the dashboard/exec-objects something to show    |
//| for what would have happened.                                      |
//+------------------------------------------------------------------+
void RegisterSyntheticFromMiss(bool isBuy,double refPrice,string reasonTag)
{
   double sl = isBuy ? (g_rangeLow  - SL_Buffer_Points*_Point) : (g_rangeHigh + SL_Buffer_Points*_Point);
   sl = NormalizeDouble(sl,_Digits);
   double riskDist = isBuy ? (refPrice-sl) : (sl-refPrice);
   if(riskDist<=0) return;

   double rr = RRValue(Take_Profit_RR);
   double tp = 0;
   if(rr>0) tp = isBuy ? (refPrice+riskDist*rr) : (refPrice-riskDist*rr);
   double lots = CalcLotSize(riskDist);
   lots = MarginCapLots(lots, isBuy, refPrice); // cap to what broker would have allowed

   datetime barCloseTime = g_lastProcessedBarTime + TriggerSeconds();

   datetime exitTime=0; double exitPx=0;
   int shift = iBarShift(_Symbol,TriggerTF(),barCloseTime,true);
   if(shift>0)
   {
      for(int f=shift-1; f>=0; f--)
      {
         if(g_timeExitServer>0 && iTime(_Symbol,TriggerTF(),f)>=g_timeExitServer)
         { exitTime=g_timeExitServer; exitPx=iOpen(_Symbol,TriggerTF(),f); break; }
         double fh=iHigh(_Symbol,TriggerTF(),f), fl=iLow(_Symbol,TriggerTF(),f);
         bool slHit = isBuy ? (fl<=sl) : (fh>=sl);
         bool tpHit = (tp>0) && (isBuy ? (fh>=tp) : (fl<=tp));
         if(slHit) { exitTime=iTime(_Symbol,TriggerTF(),f)+TriggerSeconds(); exitPx=sl; break; }
         if(tpHit) { exitTime=iTime(_Symbol,TriggerTF(),f)+TriggerSeconds(); exitPx=tp; break; }
      }
   }

   ulong synthId = ORB_SYNTH_TICKET_BASE + (ulong)ArraySize(vTrades) + 1;
   RegisterVTrade(synthId,isBuy,true,refPrice,sl,tp,lots,barCloseTime,exitTime,exitPx,
                  isBuy?g_rangeHigh:g_rangeLow,g_rangeCandleTime);

   if(isBuy) { g_tradeTakenBuy=true;  if(!g_rangeHighAnchored){g_rangeHighAnchored=true; g_rangeHighAnchorT=barCloseTime-1;} }
   else      { g_tradeTakenSell=true; if(!g_rangeLowAnchored){ g_rangeLowAnchored=true;  g_rangeLowAnchorT =barCloseTime-1;} }

   if(!Inp_StealthMode)
      Print(StringFormat("[ORB-ME SYNTH] %s withheld live (%s) -> recorded as synthetic @ %s",
            isBuy?"BUY":"SELL",reasonTag,DoubleToString(refPrice,_Digits)));
}

//+------------------------------------------------------------------+
//| Trade execution                                                    |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   if(Max_Spread_Points<=0) return true;
   long spreadPts = SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   return (double)spreadPts <= Max_Spread_Points;
}

void ExecuteBreakout(bool isBuy)
{
   // NOTE: g_tradeTakenBuy/Sell is set by CheckBreakout() BEFORE this call,
   // so this side is already consumed regardless of outcome below.
   // All early-return paths record a synthetic so the dashboard reflects what
   // would have happened on this exact candle close.

   double price = isBuy ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl = isBuy ? (g_rangeLow  - SL_Buffer_Points*_Point)
                      : (g_rangeHigh + SL_Buffer_Points*_Point);
   sl = NormalizeDouble(sl,_Digits);
   double riskDist = isBuy ? (price - sl) : (sl - price);

   if(IsBankHolidayToday(TimeCurrent()))
   {
      RegisterSyntheticFromMiss(isBuy,price,"bank holiday");
      Print("[ORB-ME] ",isBuy?"BUY":"SELL"," suppressed (bank holiday) - recorded as synthetic.");
      return;
   }
   if(IsNewsBlocked(TimeCurrent()))
   {
      RegisterSyntheticFromMiss(isBuy,price,"news block");
      Print("[ORB-ME] ",isBuy?"BUY":"SELL"," suppressed (news window) - recorded as synthetic.");
      return;
   }
   if(!SpreadOK())
   {
      RegisterSyntheticFromMiss(isBuy,price,"spread too wide");
      Print("[ORB-ME] ",isBuy?"BUY":"SELL"," suppressed (spread) - recorded as synthetic.");
      return;
   }
   if(riskDist <= 0)
   {
      RegisterSyntheticFromMiss(isBuy,price,"invalid SL distance");
      Print("[ORB-ME] ",isBuy?"BUY":"SELL"," suppressed (SL wrong side) - recorded as synthetic.");
      return;
   }

   double rr = RRValue(Take_Profit_RR);
   double tp = 0;
   if(rr > 0)
   {
      tp = isBuy ? (price + riskDist*rr) : (price - riskDist*rr);
      tp = NormalizeDouble(tp,_Digits);
   }

   double lots = CalcLotSize(riskDist);
   if(lots <= 0)
   {
      RegisterSyntheticFromMiss(isBuy,price,"risk budget below minimum lot");
      Print("[ORB-ME] ",isBuy?"BUY":"SELL"," suppressed (risk budget below minimum lot) - recorded as synthetic.");
      return;
   }
   lots = MarginCapLots(lots, isBuy, price);
   if(lots <= 0)
   {
      RegisterSyntheticFromMiss(isBuy,price,"no margin room");
      Print("[ORB-ME] ",isBuy?"BUY":"SELL"," suppressed (no margin room) - recorded as synthetic.");
      return;
   }

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(Max_Slippage_Points);

   bool ok = isBuy ? trade.Buy(lots,_Symbol,price,sl,tp,Trade_Comment)
                   : trade.Sell(lots,_Symbol,price,sl,tp,Trade_Comment);

   if(ok)
   {
      datetime barCloseTime = g_lastProcessedBarTime + TriggerSeconds();
      if(isBuy) { g_rangeHighAnchored=true; g_rangeHighAnchorT = barCloseTime-1; }
      else      { g_rangeLowAnchored=true;  g_rangeLowAnchorT  = barCloseTime-1; }

      ulong dealTicket = trade.ResultDeal();
      ulong posId = 0;
      if(dealTicket>0 && HistorySelect(TimeCurrent()-60,TimeCurrent()+60))
         posId = (ulong)HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID);
      if(posId==0) posId = trade.ResultOrder();

      // Ground truth is the position's own open price. Never the requested
      // price, never a cached level - a cached level is exactly how the
      // ORB_Scalper recenter failed silently in live trading.
      double fill = price;
      if(posId>0 && PositionSelectByTicket(posId))
         fill = PositionGetDouble(POSITION_PRICE_OPEN);

      double filledRisk = isBuy ? (fill - sl) : (sl - fill);
      if(rr>0 && filledRisk>0)
      {
         double newTp = NormalizeDouble(isBuy ? (fill + filledRisk*rr)
                                              : (fill - filledRisk*rr), _Digits);
         if(MathAbs(newTp-tp) >= _Point)
         {
            if(trade.PositionModify(posId,sl,newTp))
            {
               tp = newTp;
               if(!Inp_StealthMode)
                  Print(StringFormat("[ORB-ME] TP recentered on fill %s -> %s (restores %.2fR)",
                        DoubleToString(fill,_Digits),DoubleToString(newTp,_Digits),rr));
            }
            else
            {
               Print(StringFormat("[ORB-ME] TP recenter FAILED (retcode=%d: %s) - TP left at %s",
                     trade.ResultRetcode(),trade.ResultRetcodeDescription(),DoubleToString(tp,_Digits)));
            }
         }
      }

      RegisterVTrade(posId,isBuy,false,fill,sl,tp,lots,TimeCurrent(),0,0,isBuy?g_rangeHigh:g_rangeLow,g_rangeCandleTime);

      g_statusText = StringFormat("%s executed @ %s (lots %.2f)",isBuy?"BUY":"SELL",
                                   DoubleToString(fill,_Digits),lots);
      Print(StringFormat("[ORB-ME] %s filled. req=%s fill=%s sl=%s tp=%s lots=%.2f risk=%.1fpts",
            isBuy?"BUY":"SELL",DoubleToString(price,_Digits),DoubleToString(fill,_Digits),
            DoubleToString(sl,_Digits),DoubleToString(tp,_Digits),lots,filledRisk/_Point));

      // Post-fill audit. Step-rounding always rounds DOWN, so any breach logged
      // here is genuine slippage rather than rounding noise.
      if(g_lastRiskBudget>0.0 && filledRisk>0.0)
      {
         double actual = lots*(CashPerLotForDistance(filledRisk)+ORBCostCashPerLot());
         if(actual > g_lastRiskBudget+0.01)
            Print(StringFormat("[ORB-ME] RISK AUDIT: filled risk %.2f exceeds budget %.2f (entry slip %.1f pts).",
                  actual,g_lastRiskBudget,MathAbs(fill-price)/_Point));
      }
   }
   else
   {
      // Broker rejected the order - record as synthetic so the dashboard
      // still shows what was attempted on this candle.
      RegisterSyntheticFromMiss(isBuy,price,"broker rejected");
      Print(StringFormat("[ORB-ME] %s order FAILED (retcode=%d: %s) - recorded as synthetic.",
            isBuy?"BUY":"SELL",trade.ResultRetcode(),trade.ResultRetcodeDescription()));
   }
}

//+------------------------------------------------------------------+
//| Flat-by-the-clock exit. Closes any position this EA owns once the |
//| session's exit stamp has passed. Runs every tick; the stamp is    |
//| computed once per session in ResetSessionState.                   |
//+------------------------------------------------------------------+
void EnforceTimeExit()
{
   if(g_timeExitServer<=0) return;
   if(TimeCurrent()<g_timeExitServer) return;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);          // also selects the position
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic_Number) continue;

      if(trade.PositionClose(ticket,Max_Slippage_Points))
         Print(StringFormat("[ORB-ME] Time exit: closed #%llu at %s NY.",
               ticket,TimeToString(ServerToNY(TimeCurrent()),TIME_MINUTES)));
      else
         Print(StringFormat("[ORB-ME] Time exit close FAILED for #%llu (retcode=%d: %s)",
               ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription()));
   }
}

//+------------------------------------------------------------------+
//| Session lifecycle                                                  |
//+------------------------------------------------------------------+
void ResetSessionState(string newKey,datetime newOpenServer)
{
   g_sessionKey        = newKey;
   g_sessionOpenServer = newOpenServer;
   g_historyDerived    = false;
   g_rangeCaptured     = false;
   g_rangeHigh         = 0.0;
   g_rangeLow          = 0.0;
   g_rangeCandleTime   = 0;
   g_rangeWindowEnd    = newOpenServer + (datetime)(Range_Minutes*60);
   g_timeExitServer = 0;
   if(Time_Exit_Hour_NY >= 0)
   {
      MqlDateTime ny;
      TimeToStruct(ServerToNY(newOpenServer),ny);
      datetime ex = NYLocalToServer(ny.year,ny.mon,ny.day,Time_Exit_Hour_NY,Time_Exit_Minute_NY,0);
      // An exit clock at or before the session open belongs to the NEXT calendar
      // day - this is what makes an overnight session (e.g. a 21:00 open) work.
      if(ex <= newOpenServer) ex += 86400;
      g_timeExitServer = ex;
   }
   g_rangeRejected     = false;
   g_rangeRejectReason = "";
   g_rangeHighAnchored = false;
   g_rangeLowAnchored  = false;
   g_rangeHighAnchorT  = 0;
   g_rangeLowAnchorT   = 0;
   g_lastProcessedBarTime = 0;
   g_tradeTakenBuy     = false;
   g_tradeTakenSell    = false;
   g_statusText        = "Waiting for range candle to close";
   ArrayResize(vTrades,0);

   DeleteEAObjects(); // range box/lines + exec objects from the prior day - forgotten, no cached data
}

//+------------------------------------------------------------------+
//| Range capture                                                     |
//+------------------------------------------------------------------+
void TryCaptureRange()
{
   if(g_rangeCaptured) return;
   if(TimeCurrent() < g_rangeWindowEnd) return; // window still open

   int barsNeeded = (Range_Minutes*60) / TriggerSeconds();
   if(barsNeeded <= 0) return;

   double hi = 0.0, lo = 0.0;
   for(int b=0; b<barsNeeded; b++)
   {
      datetime want  = g_sessionOpenServer + (datetime)(b*TriggerSeconds());
      int      shift = iBarShift(_Symbol,TriggerTF(),want,true);   // exact=true: -1 when the slot has no bar
      if(shift<0) return;                                          // missing bar - retry next tick
      if(iTime(_Symbol,TriggerTF(),shift) != want) return;         // gap at this slot - retry next tick

      double bh = iHigh(_Symbol,TriggerTF(),shift);
      double bl = iLow (_Symbol,TriggerTF(),shift);
      if(bh<=0 || bl<=0 || bh<bl) return;

      if(b==0) { hi=bh; lo=bl; }
      else     { if(bh>hi) hi=bh; if(bl<lo) lo=bl; }
   }
   if(hi<=lo) return;

   g_rangeHigh       = hi;
   g_rangeLow        = lo;
   g_rangeCandleTime = g_sessionOpenServer;                        // window OPEN - left edge of the box
   g_rangeCaptured   = true;
   g_lastProcessedBarTime = g_rangeWindowEnd - (datetime)TriggerSeconds(); // last in-window bar

   double rangePts = (hi-lo)/_Point;
   if(Min_Range_Points>0 && rangePts<Min_Range_Points)
   {
      g_rangeRejected=true; g_rangeRejectReason="range too small";
   }
   else if(Max_Range_Points>0 && rangePts>Max_Range_Points)
   {
      g_rangeRejected=true; g_rangeRejectReason="range too large";
   }
   else if(Range_Max_SMA20_Ratio>0.0)
   {
      // "Range isn't huge" filter: today's opening range vs the typical size of
      // the last 20 opening ranges (same window, prior 20 sessions with a
      // captured range). A range much bigger than normal means the move already
      // happened - skip the day.
      double sumSquares=0.0, sum=0.0; int n=0;
      for(int d=1; d<=60 && n<20; d++)
      {
         datetime pastOpen = g_sessionOpenServer - (datetime)(d*86400);
         int ps = iBarShift(_Symbol,TriggerTF(),pastOpen,true);
         if(ps<0) continue;
         datetime pe = pastOpen + (datetime)(g_rangeWindowEnd-g_sessionOpenServer);
         int es = iBarShift(_Symbol,TriggerTF(),pe,true);
         if(es<0 || es>ps) continue;
         double ph=iHigh(_Symbol,TriggerTF(),ps), pl=iLow(_Symbol,TriggerTF(),ps);
         for(int b=ps-1; b>=es; b--)
         {
            ph=MathMax(ph,iHigh(_Symbol,TriggerTF(),b));
            pl=MathMin(pl,iLow (_Symbol,TriggerTF(),b));
         }
         if(ph>pl) { double r=(ph-pl); sum+=r; sumSquares+=r*r; n++; }
      }
      if(n>=10)   // need a usable sample before the filter may speak
      {
         double avg=sum/n;
         double rms=MathSqrt(sumSquares/n);
         double typical=MathMax(avg,rms);   // RMS: outlier-resistant "typical" like an ATR
         if(avg>0 && rangePts*_Point > Range_Max_SMA20_Ratio*typical)
         {
            g_rangeRejected=true;
            g_rangeRejectReason=StringFormat("range %.0fpts > %.2fx typical %.0fpts",rangePts,Range_Max_SMA20_Ratio,typical/_Point);
         }
      }
   }
   else
   {
      g_statusText = "Waiting for a trigger candle to close beyond the range";
   }

   DrawRangeCandleBox();
   Print(StringFormat("[ORB-ME] Range captured for %s: high=%s low=%s (%.1f pts) from %d bars over %d min",
         g_sessionKey,DoubleToString(hi,_Digits),DoubleToString(lo,_Digits),rangePts,barsNeeded,Range_Minutes));
}

//+------------------------------------------------------------------+
//| Breakout check - runs once per newly closed M5 bar.                |
//+------------------------------------------------------------------+
void CheckBreakout()
{
   if(!g_rangeCaptured || g_rangeRejected) return;
   if(g_tradeTakenBuy && g_tradeTakenSell) return;
   if(g_timeExitServer>0 && TimeCurrent()>=g_timeExitServer) return; // session over - no new entries past the flat clock

   datetime lastClosedBarTime = iTime(_Symbol,TriggerTF(),1);
   if(lastClosedBarTime<=g_lastProcessedBarTime) return;
   if(lastClosedBarTime < g_rangeWindowEnd) return;   // trigger bar must open at or after the window closes

   g_lastProcessedBarTime = lastClosedBarTime;

   double closePrice = iClose(_Symbol,TriggerTF(),1);
   double buf = Breakout_Buffer_Points*_Point;

   int trend = TrendDirectionForToday();   // +1 long-only, -1 short-only, 0 no filter
   bool wantBuy  = Allow_Buy  && trend>=0 && !g_tradeTakenBuy  && (closePrice > g_rangeHigh + buf);
   bool wantSell = Allow_Sell && trend<=0 && !g_tradeTakenSell && (closePrice < g_rangeLow  - buf);
   if(trend!=0)
      g_statusText = StringFormat("Trend filter: %s only (close %s SMA20)",
                                  trend>0?"LONG":"SHORT", trend>0?"above":"below");

   if(wantBuy && wantSell)
   {
      Print("[ORB-ME] Candle closed beyond BOTH levels - ambiguous, no trade taken.");
      return;
   }

   // Consume the side BEFORE calling ExecuteBreakout. This is the critical fix:
   // if ExecuteBreakout returns early for any reason (news, spread, margin, broker
   // reject), the side stays consumed and NO later bar can re-trigger it.
   // Entry is always tied to the FIRST candle that closes beyond the range.
   if(wantBuy)  { g_tradeTakenBuy  = true; ExecuteBreakout(true);  }
   if(wantSell) { g_tradeTakenSell = true; ExecuteBreakout(false); }
}

//+------------------------------------------------------------------+
//| Expert lifecycle                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(TriggerSeconds() <= 0)
   {
      Print("[ORB-ME] INIT FAILED: Trigger_Timeframe resolves to zero seconds.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(Range_Minutes <= 0 || (Range_Minutes*60) % TriggerSeconds() != 0)
   {
      Print(StringFormat("[ORB-ME] INIT FAILED: Range_Minutes=%d is not a positive whole multiple of Trigger_Timeframe (%d seconds).",
            Range_Minutes, TriggerSeconds()));
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(Max_Slippage_Points != Assumed_Slip_Points)
      Print(StringFormat("[ORB-ME] WARNING: Max_Slippage_Points=%d but Assumed_Slip_Points=%d. "
            "Up to %d points per side are unbudgeted risk - the sizer did not pay for them.",
            Max_Slippage_Points,Assumed_Slip_Points,
            (int)MathMax(0,Max_Slippage_Points-Assumed_Slip_Points)));

   if(News_Guard_Mode==NEWS_GUARD_DISABLED)
      Print("[ORB-ME] News guard is DISABLED - entries are not filtered around economic events.");

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(Max_Slippage_Points);
   trade.SetTypeFillingBySymbol(_Symbol);

   string key;
   datetime openSrv = GetActiveSessionOpenServer(TimeCurrent(),key);
   ResetSessionState(key,openSrv);

   ORBMELogTimeMapping();

   // Range may already be capturable if EA was (re)loaded mid-session.
   TryCaptureRange();
   if(g_rangeCaptured && !g_rangeRejected)
   {
      RebuildRealTradesFromHistory();  // broker fills - easy, from deal history
      DeriveSyntheticHistory();        // one-time replay for anything the EA missed
      // Catch the breakout watcher up to the newest closed bar so it doesn't
      // immediately re-fire on the same candle the derivation just consumed.
      datetime latestClosed = iTime(_Symbol,TriggerTF(),1);
      if(latestClosed>g_lastProcessedBarTime) g_lastProcessedBarTime=latestClosed;
   }
   g_historyDerived = true;

   Print("[ORB-ME] Initialized. Range candle opens ",Session_Hour_NY,":",
         StringFormat("%02d",Session_Minute_NY)," NY, 5-minute candle. Watches through to the next NY session open.");

   ORBMESelfCheckSizing();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   DeleteDashboard();
   DeleteEAObjects();
}

void OnTick()
{
   string key;
   datetime activeOpenSrv = GetActiveSessionOpenServer(TimeCurrent(),key);
   if(key != g_sessionKey)
   {
      ResetSessionState(key,activeOpenSrv);
   }

   TryCaptureRange();

   // First time the range resolves after a session reset, do the one-time
   // catch-up (covers the case where the range candle closes WHILE the EA is
   // running, mid-tick, rather than only at OnInit).
   if(g_rangeCaptured && !g_rangeRejected && !g_historyDerived)
   {
      RebuildRealTradesFromHistory();
      DeriveSyntheticHistory();
      g_historyDerived = true;
   }

   CheckBreakout();
   EnforceTimeExit();
   UpdateRealOpenTrades();
   UpdateSyntheticOpenTrades();

   UpdateRangeLevelLines();
   DrawAllTradeObjects();
   UpdateDashboard();
}
//+------------------------------------------------------------------+
