#region Using declarations
using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Media;
using NinjaTrader.Cbi;
using NinjaTrader.Data;
using NinjaTrader.Gui.Tools;
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
        AllEconomic = 3
    }

    public class ORBMarketExecNT8 : Strategy
    {
        private const string LongSignal = "ORB-L";
        private const string ShortSignal = "ORB-S";
        private const string ForexFactoryUrl = "https://nfs.faireconomy.media/ff_calendar_thisweek.json";
        private const int ForexFactoryRefreshMinutes = 65;
        private const int ForexFactoryRetryMinutes = 10;

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

        private readonly object newsSync = new object();
        private readonly List<NewsEvent> newsEvents = new List<NewsEvent>();
        private readonly HashSet<DateTime> loadedNewsWeeks = new HashSet<DateTime>();
        private DateTime nextNewsRefreshUtc = DateTime.MinValue;
        private bool newsRefreshInFlight;
        private string newsStatus = "not loaded";

        private static readonly Regex JsonObjectRegex = new Regex(@"\{(?<body>[^{}]*)\}", RegexOptions.Compiled);
        private static readonly Regex JsonFieldRegex = new Regex(@"""(?<key>title|country|date|impact|forecast|previous|actual)""\s*:\s*""(?<value>(?:\\.|[^""])*)""", RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private class NewsEvent
        {
            public DateTime Utc;
            public string Currency;
            public string Impact;
            public string Title;
        }

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Name = "ORB Market Exec NT8";
                Description = "Market-execution ORB with DST-explicit clocks, independent side expiry, account blackout flatten and automatic Forex Factory news filtering.";
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

                // Self-sufficient default: no URL/file/API key is required from the user.
                NewsMode = OrbNewsMode.HighOnly;
                NewsBlockBeforeMinutes = 30;
                NewsBlockAfterMinutes = 15;
                BlockBankHolidays = true;
                DrawObjects = true;
            }
            else if (State == State.Configure)
            {
                // Internal one-minute series gives deterministic 15m range/confirmation construction
                // and lets market entries submit immediately after the confirming minute closes.
                AddDataSeries(BarsPeriodType.Minute, 1);
            }
            else if (State == State.DataLoaded)
            {
                appTimeZone = Core.Globals.GeneralOptions.TimeZoneInfo;
                newYorkTimeZone = TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time");
                fixedEstTimeZone = TimeZoneInfo.CreateCustomTimeZone("ORB Fixed EST", TimeSpan.FromHours(-5), "ORB Fixed EST", "ORB Fixed EST");
                LoadCachedForexFactoryNews();
            }
            else if (State == State.Realtime)
            {
                QueueForexFactoryRefresh(true);
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

            if (State == State.Realtime)
                QueueForexFactoryRefresh(false);

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
                "[ORB] Session {0:yyyy-MM-dd}. Clock={1}. Range {2:HH:mm}-{3:HH:mm}. Confirm={4}m. Side expiry={5:HH:mm}. News={6} ({7}).",
                activeSessionKey, ClockMode, rangeStartLocal, rangeEndLocal, ConfirmationMinutes, sideExpiryLocal, NewsMode, newsStatus));
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
                "[ORB] Range captured: high={0} low={1} size={2:F1} ticks.", rangeHigh, rangeLow, (rangeHigh - rangeLow) / TickSize));
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
            // 09:00 means the side is dead AT 09:00. A bar that closes at 09:00 cannot trigger.
            if (!rangeCaptured || refCloseTime >= sideExpiryLocal)
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
            if (refCloseTime >= sideExpiryLocal)
                return;

            string newsReason;
            if (IsNewsBlocked(refCloseTime, out newsReason))
            {
                Print(string.Format("[ORB] {0} blocked by Forex Factory news: {1}. Side consumed.", isLong ? "LONG" : "SHORT", newsReason));
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

            // Submit on the internal 1-minute execution series, immediately after confirmation closes.
            if (isLong)
                EnterLong(1, qty, LongSignal);
            else
                EnterShort(1, qty, ShortSignal);

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
                    {
                        if (p == null || p.Instrument == null || p.MarketPosition == MarketPosition.Flat)
                            continue;
                        if (!instruments.Contains(p.Instrument))
                            instruments.Add(p.Instrument);
                    }
                }

                if (instruments.Count > 0)
                    Account.Flatten(instruments.ToArray());
                Print(string.Format("[ORB] ACCOUNT FLATTEN ALL POSITIONS at {0:yyyy-MM-dd HH:mm}. Instruments={1}.", refNow, instruments.Count));
            }
            else
            {
                if (Position.MarketPosition == MarketPosition.Long)
                    ExitLong("ORB-Blackout", "");
                else if (Position.MarketPosition == MarketPosition.Short)
                    ExitShort("ORB-Blackout", "");
            }
        }

        // -------------------- CLOCK CONVERSION --------------------
        private DateTime ToReferenceTime(DateTime appTime)
        {
            DateTime unspecified = DateTime.SpecifyKind(appTime, DateTimeKind.Unspecified);
            DateTime utc = TimeZoneInfo.ConvertTimeToUtc(unspecified, appTimeZone);
            return UtcToReference(utc);
        }

        private DateTime UtcToReference(DateTime utc)
        {
            TimeZoneInfo target = ClockMode == OrbClockMode.FixedEST ? fixedEstTimeZone : newYorkTimeZone;
            return TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), target);
        }

        private DateTime ReferenceToUtc(DateTime refTime)
        {
            TimeZoneInfo source = ClockMode == OrbClockMode.FixedEST ? fixedEstTimeZone : newYorkTimeZone;
            return TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(refTime, DateTimeKind.Unspecified), source);
        }

        private DateTime ToAppTime(DateTime refTime)
        {
            DateTime utc = ReferenceToUtc(refTime);
            return TimeZoneInfo.ConvertTimeFromUtc(utc, appTimeZone);
        }

        // -------------------- FOREX FACTORY NEWS --------------------
        // Provider is intentionally not user-configurable. The strategy uses Forex Factory's
        // public FairEconomy weekly JSON export, caches every good week locally, and never
        // requests more often than once per 65 minutes.
        private string NewsCacheDirectory
        {
            get { return Path.Combine(Core.Globals.UserDataDir, "cache", "MarketExecORB", "ForexFactory"); }
        }

        private void QueueForexFactoryRefresh(bool force)
        {
            if (NewsMode == OrbNewsMode.Disabled)
                return;

            lock (newsSync)
            {
                if (newsRefreshInFlight)
                    return;
                if (!force && DateTime.UtcNow < nextNewsRefreshUtc)
                    return;
                newsRefreshInFlight = true;
                nextNewsRefreshUtc = DateTime.UtcNow.AddMinutes(ForexFactoryRefreshMinutes);
            }

            Task.Run(() =>
            {
                bool ok = false;
                try
                {
                    string json = DownloadForexFactoryJson();
                    List<NewsEvent> parsed = ParseForexFactoryJson(json);
                    if (parsed.Count == 0)
                        throw new InvalidDataException("Forex Factory response contained no parseable events.");

                    CacheForexFactoryJson(json, parsed);
                    MergeNewsEvents(parsed);
                    ok = true;
                    lock (newsSync)
                        newsStatus = "Forex Factory live: " + parsed.Count.ToString(CultureInfo.InvariantCulture) + " events";
                    Print("[ORB NEWS] " + newsStatus);
                }
                catch (Exception ex)
                {
                    lock (newsSync)
                    {
                        newsStatus = "Forex Factory fetch failed; cache retained: " + ex.Message;
                        nextNewsRefreshUtc = DateTime.UtcNow.AddMinutes(ForexFactoryRetryMinutes);
                    }
                    Print("[ORB NEWS] " + newsStatus);
                }
                finally
                {
                    lock (newsSync)
                    {
                        newsRefreshInFlight = false;
                        if (ok)
                            nextNewsRefreshUtc = DateTime.UtcNow.AddMinutes(ForexFactoryRefreshMinutes);
                    }
                }
            });
        }

        private string DownloadForexFactoryJson()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(ForexFactoryUrl);
            req.Method = "GET";
            req.Timeout = 10000;
            req.ReadWriteTimeout = 10000;
            req.UserAgent = "NinjaTrader-ORBMarketExec/1.0";
            req.Accept = "application/json,text/plain,*/*";
            req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;

            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
            {
                if (resp.StatusCode != HttpStatusCode.OK)
                    throw new WebException("HTTP " + ((int)resp.StatusCode).ToString(CultureInfo.InvariantCulture));

                using (StreamReader reader = new StreamReader(resp.GetResponseStream()))
                {
                    string raw = reader.ReadToEnd();
                    string trimmed = raw.TrimStart();
                    if (!trimmed.StartsWith("[", StringComparison.Ordinal))
                        throw new InvalidDataException("Non-JSON/denied response received.");
                    return raw;
                }
            }
        }

        private List<NewsEvent> ParseForexFactoryJson(string json)
        {
            var result = new List<NewsEvent>();
            foreach (Match obj in JsonObjectRegex.Matches(json ?? string.Empty))
            {
                var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (Match f in JsonFieldRegex.Matches(obj.Groups["body"].Value))
                    fields[f.Groups["key"].Value] = JsonUnescape(f.Groups["value"].Value);

                string date;
                string country;
                string impact;
                if (!fields.TryGetValue("date", out date) || !fields.TryGetValue("country", out country) || !fields.TryGetValue("impact", out impact))
                    continue;

                DateTimeOffset dto;
                if (!DateTimeOffset.TryParse(date, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out dto))
                    continue;

                string title;
                fields.TryGetValue("title", out title);
                result.Add(new NewsEvent
                {
                    Utc = dto.UtcDateTime,
                    Currency = (country ?? string.Empty).Trim().ToUpperInvariant(),
                    Impact = (impact ?? string.Empty).Trim(),
                    Title = title ?? string.Empty
                });
            }
            return result;
        }

        private string JsonUnescape(string s)
        {
            if (string.IsNullOrEmpty(s))
                return string.Empty;
            try { return Regex.Unescape(s.Replace("\\/", "/")); }
            catch { return s; }
        }

        private DateTime ForexFactoryWeekStart(DateTime utc)
        {
            DateTime et = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), newYorkTimeZone);
            return et.Date.AddDays(-(int)et.DayOfWeek); // Forex Factory week: Sunday -> Saturday
        }

        private void MergeNewsEvents(List<NewsEvent> incoming)
        {
            lock (newsSync)
            {
                foreach (NewsEvent e in incoming)
                {
                    DateTime wk = ForexFactoryWeekStart(e.Utc);
                    loadedNewsWeeks.Add(wk);

                    bool duplicate = false;
                    for (int i = 0; i < newsEvents.Count; i++)
                    {
                        NewsEvent x = newsEvents[i];
                        if (x.Utc == e.Utc && x.Currency == e.Currency && string.Equals(x.Title, e.Title, StringComparison.Ordinal))
                        {
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate)
                        newsEvents.Add(e);
                }
                newsEvents.Sort((a, b) => a.Utc.CompareTo(b.Utc));
            }
        }

        private void CacheForexFactoryJson(string json, List<NewsEvent> parsed)
        {
            if (parsed == null || parsed.Count == 0)
                return;

            try
            {
                Directory.CreateDirectory(NewsCacheDirectory);
                DateTime week = ForexFactoryWeekStart(parsed[0].Utc);
                string weekly = Path.Combine(NewsCacheDirectory, "ff_calendar_" + week.ToString("yyyyMMdd", CultureInfo.InvariantCulture) + ".json");
                string latest = Path.Combine(NewsCacheDirectory, "ff_calendar_latest.json");
                File.WriteAllText(weekly, json);
                File.WriteAllText(latest, json);
            }
            catch (Exception ex)
            {
                Print("[ORB NEWS] Cache write failed: " + ex.Message);
            }
        }

        private void LoadCachedForexFactoryNews()
        {
            try
            {
                if (!Directory.Exists(NewsCacheDirectory))
                {
                    newsStatus = "no Forex Factory cache yet";
                    return;
                }

                int loaded = 0;
                foreach (string file in Directory.GetFiles(NewsCacheDirectory, "ff_calendar_*.json"))
                {
                    try
                    {
                        List<NewsEvent> parsed = ParseForexFactoryJson(File.ReadAllText(file));
                        if (parsed.Count == 0)
                            continue;
                        MergeNewsEvents(parsed);
                        loaded += parsed.Count;
                    }
                    catch { }
                }
                newsStatus = loaded > 0 ? "cache loaded: " + loaded.ToString(CultureInfo.InvariantCulture) + " events" : "cache empty";
                Print("[ORB NEWS] " + newsStatus);
            }
            catch (Exception ex)
            {
                newsStatus = "cache load failed: " + ex.Message;
                Print("[ORB NEWS] " + newsStatus);
            }
        }

        private HashSet<string> RelevantCurrencies()
        {
            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string n = Instrument.MasterInstrument.Name.ToUpperInvariant();

            if (n.StartsWith("6E") || n.StartsWith("M6E")) { set.Add("EUR"); set.Add("USD"); return set; }
            if (n.StartsWith("6B") || n.StartsWith("M6B")) { set.Add("GBP"); set.Add("USD"); return set; }
            if (n.StartsWith("6J") || n.StartsWith("M6J")) { set.Add("JPY"); set.Add("USD"); return set; }
            if (n.StartsWith("6A") || n.StartsWith("M6A")) { set.Add("AUD"); set.Add("USD"); return set; }
            if (n.StartsWith("6C") || n.StartsWith("M6C")) { set.Add("CAD"); set.Add("USD"); return set; }
            if (n.StartsWith("6S") || n.StartsWith("M6S")) { set.Add("CHF"); set.Add("USD"); return set; }
            if (n.StartsWith("6N") || n.StartsWith("M6N")) { set.Add("NZD"); set.Add("USD"); return set; }

            // Equity index, metals and energy futures used by this strategy are USD-sensitive.
            set.Add("USD");
            return set;
        }

        private bool ImpactAllowed(string impact)
        {
            if (string.Equals(impact, "High", StringComparison.OrdinalIgnoreCase))
                return true;
            if (NewsMode == OrbNewsMode.HighAndMedium && string.Equals(impact, "Medium", StringComparison.OrdinalIgnoreCase))
                return true;
            if (NewsMode == OrbNewsMode.AllEconomic &&
                (string.Equals(impact, "Medium", StringComparison.OrdinalIgnoreCase) || string.Equals(impact, "Low", StringComparison.OrdinalIgnoreCase)))
                return true;
            return false;
        }

        private bool IsNewsBlocked(DateTime refTime, out string reason)
        {
            reason = string.Empty;
            if (NewsMode == OrbNewsMode.Disabled)
                return false;

            DateTime utc = ReferenceToUtc(refTime);
            DateTime requiredWeek = ForexFactoryWeekStart(utc);
            HashSet<string> currencies = RelevantCurrencies();
            int before = Math.Max(0, NewsBlockBeforeMinutes);
            int after = Math.Max(0, NewsBlockAfterMinutes);

            lock (newsSync)
            {
                // Live fail-safe: if this week's FF data has never been obtained, do not trade blind.
                if (State == State.Realtime && !loadedNewsWeeks.Contains(requiredWeek))
                {
                    reason = "Forex Factory current-week data unavailable (fail-closed)";
                    return true;
                }

                for (int i = 0; i < newsEvents.Count; i++)
                {
                    NewsEvent e = newsEvents[i];
                    if (!currencies.Contains(e.Currency))
                        continue;

                    if (BlockBankHolidays && string.Equals(e.Impact, "Holiday", StringComparison.OrdinalIgnoreCase))
                    {
                        DateTime eventRef = UtcToReference(e.Utc);
                        if (eventRef.Date == refTime.Date)
                        {
                            reason = e.Currency + " bank holiday: " + e.Title;
                            return true;
                        }
                    }

                    if (!ImpactAllowed(e.Impact))
                        continue;
                    if (utc >= e.Utc.AddMinutes(-before) && utc <= e.Utc.AddMinutes(after))
                    {
                        reason = string.Format(CultureInfo.InvariantCulture, "{0} {1} at {2:HH:mm} ({3})", e.Currency, e.Title, UtcToReference(e.Utc), e.Impact);
                        return true;
                    }
                }
            }
            return false;
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
            Description = "At this time any still-untriggered side expires until the next ORB reset.")]
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
            Description = "Realtime: flattens every open position on the connected account at the configured blackout time.")]
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
            Description = "Historical/Strategy Analyzer sizing basis. Realtime uses connected account CashValue when available.")]
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
        [Display(Name = "News Filter", GroupName = "8. Forex Factory News", Order = 0,
            Description = "Automatic Forex Factory/FairEconomy feed. No URL, CSV, API key or manual event entry required.")]
        public OrbNewsMode NewsMode { get; set; }

        [NinjaScriptProperty]
        [Range(0, 1440)]
        [Display(Name = "Block Before Minutes", GroupName = "8. Forex Factory News", Order = 1)]
        public int NewsBlockBeforeMinutes { get; set; }

        [NinjaScriptProperty]
        [Range(0, 1440)]
        [Display(Name = "Block After Minutes", GroupName = "8. Forex Factory News", Order = 2)]
        public int NewsBlockAfterMinutes { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Block Bank Holidays", GroupName = "8. Forex Factory News", Order = 3)]
        public bool BlockBankHolidays { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Draw Objects", GroupName = "9. Visuals", Order = 0)]
        public bool DrawObjects { get; set; }
        #endregion
    }
}
