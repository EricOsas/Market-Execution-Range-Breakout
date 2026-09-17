#region Using declarations
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.ComponentModel.DataAnnotations;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows.Media;
using NinjaTrader.Cbi;
using NinjaTrader.Data;
using NinjaTrader.Gui;
using NinjaTrader.NinjaScript;
using NinjaTrader.NinjaScript.DrawingTools;
#endregion

namespace NinjaTrader.NinjaScript.Strategies
{
    public enum OrbClockMode
    {
        NewYorkWallClock = 0,
        FixedEST = 1
    }

    public enum OrbTargetMode
    {
        Off = 0,
        R_0_5 = 1,
        R_1_0 = 2,
        R_1_5 = 3,
        R_2_0 = 4,
        R_2_5 = 5,
        R_3_0 = 6,
        R_4_0 = 7,
        R_5_0 = 8
    }

    public enum OrbNewsMode
    {
        Disabled = 0,
        HighOnly = 1,
        HighAndMedium = 2,
        All = 3
    }

    public class ORBMarketExecNT8 : Strategy
    {
        private const string LongSignal = "ORB-L";
        private const string ShortSignal = "ORB-S";

        private TimeZoneInfo appTimeZone;
        private TimeZoneInfo newYorkTimeZone;
        private TimeZoneInfo fixedEstTimeZone;

        private DateTime activeSessionKey = DateTime.MinValue;
        private DateTime rangeStartLocal = DateTime.MinValue;
        private DateTime rangeEndLocal = DateTime.MinValue;
        private DateTime sideExpiryLocal = DateTime.MinValue;
        private DateTime timeExitLocal = DateTime.MinValue;
        private DateTime blackoutLocal = DateTime.MinValue;

        private double rangeHigh = double.MinValue;
        private double rangeLow = double.MaxValue;
        private bool rangeCaptured;
        private bool longConsumed;
        private bool shortConsumed;
        private bool blackoutDone;
        private bool timeExitDone;

        private DateTime confirmationBucketStart = DateTime.MinValue;
        private DateTime confirmationBucketEnd = DateTime.MinValue;
        private double confirmationClose = double.NaN;

        private readonly List<NewsEvent> newsEvents = new List<NewsEvent>();
        private DateTime newsFileLastWriteUtc = DateTime.MinValue;

        private class NewsEvent
        {
            public DateTime Utc;
            public int Impact;
            public HashSet<string> Currencies;
            public string Title;
        }

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Name = "ORB Market Exec NT8";
                Description = "Market-execution opening range breakout. Closed-candle trigger, independent side consumption, side expiry, time exit and account blackout flatten.";
                Calculate = Calculate.OnBarClose;
                EntriesPerDirection = 1;
                EntryHandling = EntryHandling.UniqueEntries;
                StopTargetHandling = StopTargetHandling.PerEntryExecution;
                IsExitOnSessionCloseStrategy = false;
                IncludeCommission = true;
                IsInstantiatedOnEachOptimizationIteration = true;
                BarsRequiredToTrade = 20;

                ClockMode = OrbClockMode.NewYorkWallClock;
                RangeStartHour = 21;
                RangeStartMinute = 0;
                RangeMinutes = 15;
                ConfirmationMinutes = 15;
                AllowLong = true;
                AllowShort = true;
                BreakoutBufferTicks = 0;
                StopBufferTicks = 0;
                SideExpiryHour = 9;
                SideExpiryMinute = 0;
                TimeExitEnabled = true;
                TimeExitHour = 15;
                TimeExitMinute = 0;
                BlackoutFlattenEnabled = false;
                BlackoutHour = 8;
                BlackoutMinute = 25;
                TargetMode = OrbTargetMode.R_1_0;
                RiskPercent = 1.0;
                StartingAccountValue = 25000;
                FixedQuantity = 0;
                RoundTurnCommissionPerContract = 0;
                AssumedSlippageTicksEachSide = 1;
                NewsMode = OrbNewsMode.Disabled;
                NewsBlockBeforeMinutes = 30;
                NewsBlockAfterMinutes = 15;
                NewsCsvPath = "orb_news.csv";
                DrawObjects = true;
            }
            else if (State == State.Configure)
            {
                AddDataSeries(BarsPeriodType.Minute, 1);
            }
            else if (State == State.DataLoaded)
            {
                appTimeZone = Core.Globals.GeneralOptions.TimeZoneInfo;
                newYorkTimeZone = TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time");
                fixedEstTimeZone = TimeZoneInfo.CreateCustomTimeZone("ORB Fixed EST", TimeSpan.FromHours(-5), "ORB Fixed EST", "ORB Fixed EST");
                LoadNewsFile(true);
            }
        }

        protected override void OnBarUpdate()
        {
            if (BarsInProgress != 1 || CurrentBars[1] < 2)
                return;

            DateTime appBarEnd = Times[1][0];
            DateTime appBarStart = appBarEnd.AddMinutes(-1);
            DateTime refBarStart = ToReferenceTime(appBarStart);
            DateTime refBarEnd = ToReferenceTime(appBarEnd);

            EnsureSession(refBarStart);
            EnforceBlackout(refBarEnd);
            EnforceTimeExit(refBarEnd);

            if (refBarStart >= rangeStartLocal && refBarStart < rangeEndLocal)
            {
                rangeHigh = Math.Max(rangeHigh, Highs[1][0]);
                rangeLow = Math.Min(rangeLow, Lows[1][0]);
                if (refBarEnd >= rangeEndLocal)
                    FinalizeRange();
                return;
            }

            if (rangeCaptured && refBarStart >= rangeEndLocal)
                ProcessConfirmationMinute(refBarStart, refBarEnd, Closes[1][0]);
        }

        private void EnsureSession(DateTime refNow)
        {
            DateTime todayOpen = refNow.Date.AddHours(RangeStartHour).AddMinutes(RangeStartMinute);
            DateTime key = refNow >= todayOpen ? todayOpen.Date : todayOpen.AddDays(-1).Date;
            if (key == activeSessionKey)
                return;

            activeSessionKey = key;
            rangeStartLocal = key.AddHours(RangeStartHour).AddMinutes(RangeStartMinute);
            rangeEndLocal = rangeStartLocal.AddMinutes(RangeMinutes);
            sideExpiryLocal = ResolveAfterOpen(rangeStartLocal, SideExpiryHour, SideExpiryMinute);
            timeExitLocal = TimeExitEnabled ? ResolveAfterOpen(rangeStartLocal, TimeExitHour, TimeExitMinute) : DateTime.MaxValue;
            blackoutLocal = BlackoutFlattenEnabled ? ResolveAfterOpen(rangeStartLocal, BlackoutHour, BlackoutMinute) : DateTime.MaxValue;

            rangeHigh = double.MinValue;
            rangeLow = double.MaxValue;
            rangeCaptured = false;
            longConsumed = false;
            shortConsumed = false;
            blackoutDone = false;
            timeExitDone = false;
            confirmationBucketStart = DateTime.MinValue;
            confirmationBucketEnd = DateTime.MinValue;
            confirmationClose = double.NaN;

            if (DrawObjects)
            {
                RemoveDrawObject("ORB_RANGE");
                RemoveDrawObject("ORB_HIGH");
                RemoveDrawObject("ORB_LOW");
            }

            Print(string.Format(CultureInfo.InvariantCulture,
                "[ORB] Session {0:yyyy-MM-dd}. Clock={1}. Range {2:HH:mm}-{3:HH:mm}. Side expiry {4:HH:mm}. Confirmation={5}m.",
                activeSessionKey, ClockMode, rangeStartLocal, rangeEndLocal, sideExpiryLocal, ConfirmationMinutes));
        }

        private DateTime ResolveAfterOpen(DateTime sessionOpen, int hour, int minute)
        {
            DateTime t = sessionOpen.Date.AddHours(hour).AddMinutes(minute);
            if (t <= sessionOpen)
                t = t.AddDays(1);
            return t;
        }

        private void FinalizeRange()
        {
            if (rangeCaptured || rangeHigh == double.MinValue || rangeLow == double.MaxValue || rangeHigh <= rangeLow)
                return;

            rangeCaptured = true;
            if (DrawObjects)
            {
                Draw.Rectangle(this, "ORB_RANGE", false, ToAppTime(rangeStartLocal), rangeHigh, ToAppTime(rangeEndLocal), rangeLow,
                    Brushes.Gray, Brushes.Transparent, 20);
                Draw.Line(this, "ORB_HIGH", false, ToAppTime(rangeStartLocal), rangeHigh, ToAppTime(sideExpiryLocal), rangeHigh,
                    Brushes.DodgerBlue, DashStyleHelper.Solid, 2);
                Draw.Line(this, "ORB_LOW", false, ToAppTime(rangeStartLocal), rangeLow, ToAppTime(sideExpiryLocal), rangeLow,
                    Brushes.Gray, DashStyleHelper.Solid, 2);
            }

            Print(string.Format(CultureInfo.InvariantCulture,
                "[ORB] Range captured: high={0} low={1} size={2:F1} ticks.",
                rangeHigh, rangeLow, (rangeHigh - rangeLow) / TickSize));
        }

        private void ProcessConfirmationMinute(DateTime refStart, DateTime refEnd, double minuteClose)
        {
            if (refStart >= sideExpiryLocal)
                return;

            int bucketMinutes = Math.Max(1, ConfirmationMinutes);
            double elapsed = (refStart - rangeEndLocal).TotalMinutes;
            if (elapsed < 0)
                return;

            int bucketIndex = (int)Math.Floor(elapsed / bucketMinutes);
            DateTime bucketStart = rangeEndLocal.AddMinutes(bucketIndex * bucketMinutes);
            DateTime bucketEnd = bucketStart.AddMinutes(bucketMinutes);

            if (confirmationBucketStart != bucketStart)
            {
                confirmationBucketStart = bucketStart;
                confirmationBucketEnd = bucketEnd;
            }

            confirmationClose = minuteClose;
            if (refEnd >= confirmationBucketEnd)
                EvaluateConfirmationClose(confirmationBucketEnd, confirmationClose);
        }

        private void EvaluateConfirmationClose(DateTime refCloseTime, double closePrice)
        {
            if (!rangeCaptured || refCloseTime > sideExpiryLocal)
                return;

            double buffer = Math.Max(0, BreakoutBufferTicks) * TickSize;
            bool wantLong = AllowLong && !longConsumed && closePrice > rangeHigh + buffer;
            bool wantShort = AllowShort && !shortConsumed && closePrice < rangeLow - buffer;

            if (wantLong && wantShort)
                return;

            if (wantLong)
            {
                longConsumed = true;
                TryEnter(true, closePrice, refCloseTime);
            }
            if (wantShort)
            {
                shortConsumed = true;
                TryEnter(false, closePrice, refCloseTime);
            }
        }

        private void TryEnter(bool isLong, double confirmationClosePrice, DateTime refCloseTime)
        {
            if (refCloseTime > sideExpiryLocal)
                return;

            if (IsNewsBlocked(refCloseTime))
            {
                Print(string.Format("[ORB] {0} blocked by news at {1:yyyy-MM-dd HH:mm}. Side consumed.", isLong ? "LONG" : "SHORT", refCloseTime));
                return;
            }

            double entryReference = confirmationClosePrice;
            double stop = isLong
                ? rangeLow - Math.Max(0, StopBufferTicks) * TickSize
                : rangeHigh + Math.Max(0, StopBufferTicks) * TickSize;
            double riskDistance = Math.Abs(entryReference - stop);
            if (riskDistance <= TickSize * 0.1)
                return;

            int qty = ComputeQuantity(riskDistance);
            if (qty <= 0)
            {
                Print("[ORB] Entry refused: all-in risk budget cannot afford one contract.");
                return;
            }

            double rr = TargetR();
            double target = rr > 0 ? (isLong ? entryReference + riskDistance * rr : entryReference - riskDistance * rr) : 0;
            string signal = isLong ? LongSignal : ShortSignal;

            SetStopLoss(signal, CalculationMode.Price, Instrument.MasterInstrument.RoundToTickSize(stop), false);
            if (rr > 0)
                SetProfitTarget(signal, CalculationMode.Price, Instrument.MasterInstrument.RoundToTickSize(target));

            if (isLong)
                EnterLong(0, qty, LongSignal);
            else
                EnterShort(0, qty, ShortSignal);

            if (DrawObjects)
            {
                string prefix = isLong ? "ORB_L_" : "ORB_S_";
                DateTime drawStart = ToAppTime(refCloseTime);
                DateTime drawEnd = drawStart.AddMinutes(Math.Max(ConfirmationMinutes * 3, 45));
                string id = refCloseTime.Ticks.ToString(CultureInfo.InvariantCulture);
                Draw.Line(this, prefix + id + "_ENTRY", false, drawStart, entryReference, drawEnd, entryReference, Brushes.DodgerBlue, DashStyleHelper.Solid, 2);
                Draw.Line(this, prefix + id + "_SL", false, drawStart, stop, drawEnd, stop, Brushes.Gray, DashStyleHelper.Dash, 2);
                if (rr > 0)
                    Draw.Line(this, prefix + id + "_TP", false, drawStart, target, drawEnd, target, Brushes.DodgerBlue, DashStyleHelper.Dash, 2);
            }

            Print(string.Format(CultureInfo.InvariantCulture,
                "[ORB] {0} market trigger. close={1} stop={2} target={3} qty={4}.",
                isLong ? "LONG" : "SHORT", entryReference, stop, rr > 0 ? target.ToString(CultureInfo.InvariantCulture) : "OFF", qty));
        }

        private int ComputeQuantity(double riskDistance)
        {
            if (FixedQuantity > 0)
                return FixedQuantity;

            double accountValue = StartingAccountValue;
            try
            {
                if (State == State.Realtime && Account != null)
                {
                    double cash = Account.Get(AccountItem.CashValue, Account.Denomination);
                    if (!double.IsNaN(cash) && cash > 0)
                        accountValue = cash;
                }
            }
            catch { }

            if (accountValue <= 0 || RiskPercent <= 0)
                return 0;

            double budget = accountValue * RiskPercent / 100.0;
            double pointValue = Instrument.MasterInstrument.PointValue;
            double stopCash = riskDistance * pointValue;
            double slippageCash = Math.Max(0, AssumedSlippageTicksEachSide) * TickSize * pointValue * 2.0;
            double perContract = stopCash + Math.Max(0, RoundTurnCommissionPerContract) + slippageCash;
            return perContract > 0 ? Math.Max(0, (int)Math.Floor(budget / perContract)) : 0;
        }

        private double TargetR()
        {
            switch (TargetMode)
            {
                case OrbTargetMode.R_0_5: return 0.5;
                case OrbTargetMode.R_1_0: return 1.0;
                case OrbTargetMode.R_1_5: return 1.5;
                case OrbTargetMode.R_2_0: return 2.0;
                case OrbTargetMode.R_2_5: return 2.5;
                case OrbTargetMode.R_3_0: return 3.0;
                case OrbTargetMode.R_4_0: return 4.0;
                case OrbTargetMode.R_5_0: return 5.0;
                default: return 0.0;
            }
        }

        private void EnforceTimeExit(DateTime refNow)
        {
            if (!TimeExitEnabled || timeExitDone || refNow < timeExitLocal)
                return;
            timeExitDone = true;

            if (Position.MarketPosition == MarketPosition.Long)
                ExitLong("ORB-TimeExit", "");
            else if (Position.MarketPosition == MarketPosition.Short)
                ExitShort("ORB-TimeExit", "");
        }

        private void EnforceBlackout(DateTime refNow)
        {
            if (!BlackoutFlattenEnabled || blackoutDone || refNow < blackoutLocal)
                return;
            blackoutDone = true;

            if (State == State.Realtime && Account != null)
            {
                var instruments = new List<Instrument>();
                lock (Account.Positions)
                {
                    foreach (Position p in Account.Positions)
                        if (p != null && p.MarketPosition != MarketPosition.Flat && p.Instrument != null && !instruments.Contains(p.Instrument))
                            instruments.Add(p.Instrument);
                }
                lock (Account.Orders)
                {
                    foreach (Order o in Account.Orders)
                        if (o != null && o.Instrument != null && !instruments.Contains(o.Instrument)
                            && (o.OrderState == OrderState.Accepted || o.OrderState == OrderState.Working || o.OrderState == OrderState.Submitted || o.OrderState == OrderState.TriggerPending))
                            instruments.Add(o.Instrument);
                }

                if (instruments.Count > 0)
                    Account.Flatten(instruments);
                Print(string.Format("[ORB] ACCOUNT FLATTEN EVERYTHING at {0:yyyy-MM-dd HH:mm}. Instruments={1}.", refNow, instruments.Count));
            }
            else
            {
                if (Position.MarketPosition == MarketPosition.Long)
                    ExitLong("ORB-Blackout", "");
                else if (Position.MarketPosition == MarketPosition.Short)
                    ExitShort("ORB-Blackout", "");
            }
        }

        private DateTime ToReferenceTime(DateTime appTime)
        {
            DateTime unspecified = DateTime.SpecifyKind(appTime, DateTimeKind.Unspecified);
            DateTime utc = TimeZoneInfo.ConvertTimeToUtc(unspecified, appTimeZone);
            TimeZoneInfo target = ClockMode == OrbClockMode.FixedEST ? fixedEstTimeZone : newYorkTimeZone;
            return TimeZoneInfo.ConvertTimeFromUtc(utc, target);
        }

        private DateTime ToAppTime(DateTime refTime)
        {
            TimeZoneInfo source = ClockMode == OrbClockMode.FixedEST ? fixedEstTimeZone : newYorkTimeZone;
            DateTime unspecified = DateTime.SpecifyKind(refTime, DateTimeKind.Unspecified);
            DateTime utc = TimeZoneInfo.ConvertTimeToUtc(unspecified, source);
            return TimeZoneInfo.ConvertTimeFromUtc(utc, appTimeZone);
        }

        private bool IsNewsBlocked(DateTime refTime)
        {
            if (NewsMode == OrbNewsMode.Disabled)
                return false;

            LoadNewsFile(false);
            if (newsEvents.Count == 0)
                return false;

            DateTime app = ToAppTime(refTime);
            DateTime utc = TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(app, DateTimeKind.Unspecified), appTimeZone);
            string instrumentCurrency = GuessCurrency();
            TimeSpan before = TimeSpan.FromMinutes(Math.Max(0, NewsBlockBeforeMinutes));
            TimeSpan after = TimeSpan.FromMinutes(Math.Max(0, NewsBlockAfterMinutes));

            foreach (NewsEvent ev in newsEvents)
            {
                if (!ImpactAllowed(ev.Impact))
                    continue;
                if (ev.Currencies.Count > 0 && !ev.Currencies.Contains(instrumentCurrency) && !ev.Currencies.Contains("ALL"))
                    continue;
                if (utc >= ev.Utc - before && utc <= ev.Utc + after)
                    return true;
            }
            return false;
        }

        private bool ImpactAllowed(int impact)
        {
            if (NewsMode == OrbNewsMode.All) return true;
            if (NewsMode == OrbNewsMode.HighOnly) return impact >= 3;
            if (NewsMode == OrbNewsMode.HighAndMedium) return impact >= 2;
            return false;
        }

        private string GuessCurrency()
        {
            string name = Instrument.MasterInstrument.Name.ToUpperInvariant();
            if (name.StartsWith("6E") || name.StartsWith("M6E")) return "EUR";
            if (name.StartsWith("6B") || name.StartsWith("M6B")) return "GBP";
            if (name.StartsWith("6J") || name.StartsWith("M6J")) return "JPY";
            if (name.StartsWith("6A") || name.StartsWith("M6A")) return "AUD";
            if (name.StartsWith("6C") || name.StartsWith("M6C")) return "CAD";
            if (name.StartsWith("6S") || name.StartsWith("M6S")) return "CHF";
            if (name.StartsWith("6N") || name.StartsWith("M6N")) return "NZD";
            return "USD";
        }

        private string ResolveNewsCsvPath()
        {
            if (Path.IsPathRooted(NewsCsvPath))
                return NewsCsvPath;
            return Path.Combine(Core.Globals.UserDataDir, NewsCsvPath);
        }

        private void LoadNewsFile(bool force)
        {
            if (NewsMode == OrbNewsMode.Disabled && !force)
                return;

            string path = ResolveNewsCsvPath();
            if (!File.Exists(path))
            {
                if (force && NewsMode != OrbNewsMode.Disabled)
                    Print("[ORB] News CSV not found: " + path);
                newsEvents.Clear();
                return;
            }

            DateTime writeUtc = File.GetLastWriteTimeUtc(path);
            if (!force && writeUtc == newsFileLastWriteUtc)
                return;

            newsFileLastWriteUtc = writeUtc;
            newsEvents.Clear();
            foreach (string raw in File.ReadAllLines(path))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#"))
                    continue;

                string[] p = line.Split(new[] { ',' }, 4);
                if (p.Length < 3)
                    continue;

                DateTime utc;
                int impact;
                if (!DateTime.TryParse(p[0], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out utc))
                    continue;
                if (!int.TryParse(p[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out impact))
                    continue;

                HashSet<string> ccys = new HashSet<string>(
                    p[2].Split(new[] { '|', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries)
                        .Select(x => x.Trim().ToUpperInvariant()));

                newsEvents.Add(new NewsEvent
                {
                    Utc = utc,
                    Impact = impact,
                    Currencies = ccys,
                    Title = p.Length >= 4 ? p[3].Trim() : ""
                });
            }
            newsEvents.Sort((a, b) => a.Utc.CompareTo(b.Utc));
            Print(string.Format("[ORB] Loaded {0} news events from {1}.", newsEvents.Count, path));
        }

        #region Properties
        [NinjaScriptProperty]
        [Display(Name = "Clock Mode", GroupName = "1. Session", Order = 0,
            Description = "NewYorkWallClock: 21:00 always means 9pm New York and auto-shifts with DST. FixedEST: 21:00 always means UTC-5 and never shifts.")]
        public OrbClockMode ClockMode { get; set; }

        [NinjaScriptProperty]
        [Range(0, 23)]
        [Display(Name = "Range Start Hour", GroupName = "1. Session", Order = 1)]
        public int RangeStartHour { get; set; }

        [NinjaScriptProperty]
        [Range(0, 59)]
        [Display(Name = "Range Start Minute", GroupName = "1. Session", Order = 2)]
        public int RangeStartMinute { get; set; }

        [NinjaScriptProperty]
        [Range(1, 240)]
        [Display(Name = "Range Minutes", GroupName = "2. Range & Trigger", Order = 0)]
        public int RangeMinutes { get; set; }

        [NinjaScriptProperty]
        [Range(1, 240)]
        [Display(Name = "Confirmation Minutes", GroupName = "2. Range & Trigger", Order = 1)]
        public int ConfirmationMinutes { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Allow Long", GroupName = "2. Range & Trigger", Order = 2)]
        public bool AllowLong { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Allow Short", GroupName = "2. Range & Trigger", Order = 3)]
        public bool AllowShort { get; set; }

        [NinjaScriptProperty]
        [Range(0, 100000)]
        [Display(Name = "Breakout Buffer Ticks", GroupName = "2. Range & Trigger", Order = 4)]
        public int BreakoutBufferTicks { get; set; }

        [NinjaScriptProperty]
        [Range(0, 23)]
        [Display(Name = "Side Expiry Hour", GroupName = "3. Entry Cutoff", Order = 0,
            Description = "After this clock time, any untriggered side expires until the next range reset.")]
        public int SideExpiryHour { get; set; }

        [NinjaScriptProperty]
        [Range(0, 59)]
        [Display(Name = "Side Expiry Minute", GroupName = "3. Entry Cutoff", Order = 1)]
        public int SideExpiryMinute { get; set; }

        [NinjaScriptProperty]
        [Range(0, 100000)]
        [Display(Name = "Stop Buffer Ticks", GroupName = "4. Stop & Target", Order = 0)]
        public int StopBufferTicks { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Target", GroupName = "4. Stop & Target", Order = 1)]
        public OrbTargetMode TargetMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Time Exit Enabled", GroupName = "5. Time Exit", Order = 0)]
        public bool TimeExitEnabled { get; set; }

        [NinjaScriptProperty]
        [Range(0, 23)]
        [Display(Name = "Time Exit Hour", GroupName = "5. Time Exit", Order = 1)]
        public int TimeExitHour { get; set; }

        [NinjaScriptProperty]
        [Range(0, 59)]
        [Display(Name = "Time Exit Minute", GroupName = "5. Time Exit", Order = 2)]
        public int TimeExitMinute { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Blackout Flatten Enabled", GroupName = "6. Blackout", Order = 0,
            Description = "Realtime: flattens every open account position and working order instrument at the configured blackout time.")]
        public bool BlackoutFlattenEnabled { get; set; }

        [NinjaScriptProperty]
        [Range(0, 23)]
        [Display(Name = "Blackout Hour", GroupName = "6. Blackout", Order = 1)]
        public int BlackoutHour { get; set; }

        [NinjaScriptProperty]
        [Range(0, 59)]
        [Display(Name = "Blackout Minute", GroupName = "6. Blackout", Order = 2)]
        public int BlackoutMinute { get; set; }

        [NinjaScriptProperty]
        [Range(0.001, 100)]
        [Display(Name = "Risk Percent", GroupName = "7. Risk", Order = 0)]
        public double RiskPercent { get; set; }

        [NinjaScriptProperty]
        [Range(0, double.MaxValue)]
        [Display(Name = "Starting Account Value", GroupName = "7. Risk", Order = 1,
            Description = "Historical/Analyzer sizing basis. Realtime uses connected account CashValue when available.")]
        public double StartingAccountValue { get; set; }

        [NinjaScriptProperty]
        [Range(0, 100000)]
        [Display(Name = "Fixed Quantity", GroupName = "7. Risk", Order = 2, Description = "0 = risk-based sizing.")]
        public int FixedQuantity { get; set; }

        [NinjaScriptProperty]
        [Range(0, double.MaxValue)]
        [Display(Name = "Round-Turn Commission / Contract", GroupName = "7. Risk", Order = 3)]
        public double RoundTurnCommissionPerContract { get; set; }

        [NinjaScriptProperty]
        [Range(0, 1000)]
        [Display(Name = "Assumed Slippage Ticks Each Side", GroupName = "7. Risk", Order = 4)]
        public int AssumedSlippageTicksEachSide { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "News Mode", GroupName = "8. News", Order = 0)]
        public OrbNewsMode NewsMode { get; set; }

        [NinjaScriptProperty]
        [Range(0, 1440)]
        [Display(Name = "Block Before Minutes", GroupName = "8. News", Order = 1)]
        public int NewsBlockBeforeMinutes { get; set; }

        [NinjaScriptProperty]
        [Range(0, 1440)]
        [Display(Name = "Block After Minutes", GroupName = "8. News", Order = 2)]
        public int NewsBlockAfterMinutes { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "News CSV Path", GroupName = "8. News", Order = 3,
            Description = "Relative path under Documents\\NinjaTrader 8\\. Format: UTC_ISO,impact(1-3),currencies,title.")]
        public string NewsCsvPath { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Draw Objects", GroupName = "9. Visuals", Order = 0)]
        public bool DrawObjects { get; set; }
        #endregion
    }
}
