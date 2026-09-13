//+------------------------------------------------------------------+
//|                                                    EA13.mq5      |
//|          Multi-Timeframe Market Structure Expert Advisor        |
//|                                                                  |
//|  Pure MQL5 / MetaTrader 5                                       |
//|  Confirmed swing structure - non-repainting                     |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EA13 - Multi-Timeframe Confirmed Market Structure EA"
#property description "Pure MQL5. Confirmed swing highs/lows. Non-repainting."
#property description "Higher timeframe trend + lower timeframe entry."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| ENUMS                                                            |
//+------------------------------------------------------------------+
enum ENUM_SL_MODE
  {
   SL_IN_POINTS = 0,
   SL_IN_PERCENT = 1
  };

enum ENUM_TP_MODE
  {
   TP_DISABLED = 0,
   TP_IN_POINTS = 1,
   TP_IN_PERCENT = 2
  };

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+

input group "=== TIMEFRAMES ==="

input ENUM_TIMEFRAMES InpSignalTimeframe =
   PERIOD_M15;                       // Signal timeframe

input ENUM_TIMEFRAMES InpTrendTimeframe =
   PERIOD_H1;                        // Higher timeframe


input group "=== MARKET STRUCTURE ==="

input int InpSwingStrength = 2;      // Bars left/right for pivot
input int InpTrendConfirmations = 3; // X confirmations for HTF trend
input int InpEntryConfirmations = 2; // Y confirmations for signal entry


input group "=== RISK MANAGEMENT ==="

input double InpRiskMoney = 50.0;    // Money risk per trade
input ENUM_SL_MODE InpSLMode =
   SL_IN_POINTS;                     // Stop loss mode

input double InpSLValue = 500.0;     // SL points or percent

input ENUM_TP_MODE InpTPMode =
   TP_IN_POINTS;                     // Take profit mode

input double InpTPValue = 1000.0;    // TP points or percent


input group "=== TRADING ==="

input bool InpAllowBuy = true;       // Allow buy trades
input bool InpAllowSell = true;      // Allow sell trades

input ulong InpMagicNumber = 130013; // EA magic number

input int InpDeviationPoints = 20;   // Maximum deviation


input group "=== VISUALIZATION ==="

input bool InpDrawSignalSwings = true;
input bool InpDrawTrendSwings = true;
input bool InpDrawTrendObjects = true;

input color InpSignalHighColor = clrDodgerBlue;
input color InpSignalLowColor  = clrDeepSkyBlue;

input color InpTrendHighColor = clrOrangeRed;
input color InpTrendLowColor  = clrGold;

input color InpLongTrendColor  = clrLimeGreen;
input color InpShortTrendColor = clrTomato;


//+------------------------------------------------------------------+
//| STRUCTURES                                                       |
//+------------------------------------------------------------------+

struct SwingPoint
  {
   datetime time;
   double   price;
   bool     isHigh;
   int      barIndex;
  };


//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+

CTrade trade;

SwingPoint g_signalSwings[];
SwingPoint g_trendSwings[];

datetime g_lastSignalBarTime = 0;
datetime g_lastTrendBarTime  = 0;

datetime g_lastEntryStructureTime = 0;

bool g_longTrend  = false;
bool g_shortTrend = false;

double g_protectedTrendLow  = 0.0;
double g_protectedTrendHigh = 0.0;

datetime g_trendStartTime = 0;
datetime g_trendBreakTime = 0;

int g_trendDirection = 0;
//  1 = bullish
// -1 = bearish
//  0 = none


//+------------------------------------------------------------------+
//| OBJECT PREFIXES                                                  |
//+------------------------------------------------------------------+

string PREFIX_SIGNAL_HIGH = "EA13_SIG_HIGH_";
string PREFIX_SIGNAL_LOW  = "EA13_SIG_LOW_";

string PREFIX_TREND_HIGH  = "EA13_HTF_HIGH_";
string PREFIX_TREND_LOW   = "EA13_HTF_LOW_";

string PREFIX_TREND_LINE  = "EA13_TREND_";


//+------------------------------------------------------------------+
//| UTILITY: Normalize price                                         |
//+------------------------------------------------------------------+

double NormalizePrice(const double price)
  {
   int digits = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   return NormalizeDouble(price,digits);
  }


//+------------------------------------------------------------------+
//| UTILITY: Get point                                               |
//+------------------------------------------------------------------+

double GetPoint()
  {
   return SymbolInfoDouble(_Symbol,SYMBOL_POINT);
  }


//+------------------------------------------------------------------+
//| UTILITY: Validate timeframe                                      |
//+------------------------------------------------------------------+

bool ValidateTimeframes()
  {
   int signalSeconds = PeriodSeconds(InpSignalTimeframe);
   int trendSeconds  = PeriodSeconds(InpTrendTimeframe);

   if(signalSeconds <= 0 || trendSeconds <= 0)
     {
      Print("EA13: Invalid timeframe.");
      return false;
     }

   if(trendSeconds <= signalSeconds)
     {
      Print("EA13: Warning - Trend timeframe should normally be higher "
            "than Signal timeframe.");
     }

   return true;
  }


//+------------------------------------------------------------------+
//| GET CLOSED BARS                                                  |
//+------------------------------------------------------------------+

int GetRates(ENUM_TIMEFRAMES timeframe,
             MqlRates &rates[])
  {
   ArraySetAsSeries(rates,false);

   int copied = CopyRates(_Symbol,
                          timeframe,
                          0,
                          5000,
                          rates);

   if(copied <= 0)
     {
      Print("EA13: CopyRates failed. TF=",
            EnumToString(timeframe),
            " Error=",
            GetLastError());

      return 0;
     }

   return copied;
  }


//+------------------------------------------------------------------+
//| CHECK PIVOT HIGH                                                 |
//+------------------------------------------------------------------+

bool IsPivotHigh(const MqlRates &rates[],
                 const int index,
                 const int strength)
  {
   int total = ArraySize(rates);

   if(index - strength < 0)
      return false;

   if(index + strength >= total)
      return false;

   double candidate = rates[index].high;

   for(int i=1; i<=strength; i++)
     {
      if(candidate <= rates[index-i].high)
         return false;

      if(candidate <= rates[index+i].high)
         return false;
     }

   return true;
  }


//+------------------------------------------------------------------+
//| CHECK PIVOT LOW                                                  |
//+------------------------------------------------------------------+

bool IsPivotLow(const MqlRates &rates[],
                const int index,
                const int strength)
  {
   int total = ArraySize(rates);

   if(index - strength < 0)
      return false;

   if(index + strength >= total)
      return false;

   double candidate = rates[index].low;

   for(int i=1; i<=strength; i++)
     {
      if(candidate >= rates[index-i].low)
         return false;

      if(candidate >= rates[index+i].low)
         return false;
     }

   return true;
  }


//+------------------------------------------------------------------+
//| CHECK DUPLICATE SWING                                            |
//+------------------------------------------------------------------+

bool SwingExists(const SwingPoint &array[],
                 const datetime time,
                 const bool isHigh)
  {
   int count = ArraySize(array);

   for(int i=0; i<count; i++)
     {
      if(array[i].time == time &&
         array[i].isHigh == isHigh)
         return true;
     }

   return false;
  }


//+------------------------------------------------------------------+
//| ADD SWING                                                        |
//+------------------------------------------------------------------+

void AddSwing(SwingPoint &array[],
              const datetime time,
              const double price,
              const bool isHigh,
              const int barIndex)
  {
   if(SwingExists(array,time,isHigh))
      return;

   int size = ArraySize(array);

   ArrayResize(array,size+1);

   array[size].time     = time;
   array[size].price    = price;
   array[size].isHigh   = isHigh;
   array[size].barIndex = barIndex;
  }


//+------------------------------------------------------------------+
//| SORT SWINGS                                                      |
//+------------------------------------------------------------------+

void SortSwings(SwingPoint &array[])
  {
   int count = ArraySize(array);

   for(int i=0; i<count-1; i++)
     {
      for(int j=i+1; j<count; j++)
        {
         if(array[j].time < array[i].time)
           {
            SwingPoint temp = array[i];
            array[i] = array[j];
            array[j] = temp;
           }
        }
     }
  }


//+------------------------------------------------------------------+
//| BUILD SWINGS                                                     |
//+------------------------------------------------------------------+

void BuildSwings(ENUM_TIMEFRAMES timeframe,
                 SwingPoint &output[])
  {
   ArrayResize(output,0);

   MqlRates rates[];

   int total = GetRates(timeframe,rates);

   if(total <= 0)
      return;

   // Ignore the currently forming candle.
   int lastClosed = total - 2;

   for(int i=InpSwingStrength;
       i<=lastClosed-InpSwingStrength;
       i++)
     {
      // The pivot is confirmed only when the required
      // candles to its right have closed.
      if(IsPivotHigh(rates,i,InpSwingStrength))
        {
         AddSwing(output,
                  rates[i].time,
                  rates[i].high,
                  true,
                  i);
        }

      if(IsPivotLow(rates,i,InpSwingStrength))
        {
         AddSwing(output,
                  rates[i].time,
                  rates[i].low,
                  false,
                  i);
        }
     }

   SortSwings(output);
  }


//+------------------------------------------------------------------+
//| CREATE ARROW OBJECT                                              |
//+------------------------------------------------------------------+

void DrawSwingObject(const SwingPoint &swing,
                     const bool isTrendTF)
  {
   string prefix;

   color objectColor;

   ENUM_OBJECT objectType;

   double offset;

   if(isTrendTF)
     {
      if(swing.isHigh)
        {
         prefix = PREFIX_TREND_HIGH;
         objectColor = InpTrendHighColor;
         objectType = OBJ_ARROW_DOWN;
        }
      else
        {
         prefix = PREFIX_TREND_LOW;
         objectColor = InpTrendLowColor;
         objectType = OBJ_ARROW_UP;
        }

      offset = 0.0;
     }
   else
     {
      if(swing.isHigh)
        {
         prefix = PREFIX_SIGNAL_HIGH;
         objectColor = InpSignalHighColor;
         objectType = OBJ_ARROW_DOWN;
        }
      else
        {
         prefix = PREFIX_SIGNAL_LOW;
         objectColor = InpSignalLowColor;
         objectType = OBJ_ARROW_UP;
        }

      offset = 0.0;
     }

   string name = prefix +
                 IntegerToString((long)swing.time);

   if(ObjectFind(0,name) >= 0)
      return;

   if(!ObjectCreate(0,
                    name,
                    objectType,
                    0,
                    swing.time,
                    swing.price))
     {
      return;
     }

   ObjectSetInteger(0,name,OBJPROP_COLOR,objectColor);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,false);
  }


//+------------------------------------------------------------------+
//| DRAW ALL SWINGS                                                  |
//+------------------------------------------------------------------+

void DrawSwings(SwingPoint &array[],
                const bool isTrendTF)
  {
   int count = ArraySize(array);

   for(int i=0; i<count; i++)
      DrawSwingObject(array[i],isTrendTF);
  }


//+------------------------------------------------------------------+
//| GET MOST RECENT HIGH                                             |
//+------------------------------------------------------------------+

int FindLastHigh(const SwingPoint &array[])
  {
   for(int i=ArraySize(array)-1; i>=0; i--)
     {
      if(array[i].isHigh)
         return i;
     }

   return -1;
  }


//+------------------------------------------------------------------+
//| GET MOST RECENT LOW                                              |
//+------------------------------------------------------------------+

int FindLastLow(const SwingPoint &array[])
  {
   for(int i=ArraySize(array)-1; i>=0; i--)
     {
      if(!array[i].isHigh)
         return i;
     }

   return -1;
  }


//+------------------------------------------------------------------+
//| COUNT BULLISH STRUCTURE                                          |
//+------------------------------------------------------------------+

int CountBullishStructure(const SwingPoint &array[],
                          const int endIndex)
  {
   int highs = 0;
   int lows  = 0;

   double previousHigh = 0.0;
   double previousLow  = 0.0;

   bool haveHigh = false;
   bool haveLow  = false;

   int confirmations = 0;

   for(int i=0; i<=endIndex; i++)
     {
      if(array[i].isHigh)
        {
         if(haveHigh && array[i].price > previousHigh)
            highs++;

         previousHigh = array[i].price;
         haveHigh = true;
        }
      else
        {
         if(haveLow && array[i].price > previousLow)
            lows++;

         previousLow = array[i].price;
         haveLow = true;
        }

      if(highs > confirmations &&
         lows > confirmations)
        {
         confirmations++;
        }
     }

   return confirmations;
  }


//+------------------------------------------------------------------+
//| COUNT BEARISH STRUCTURE                                          |
//+------------------------------------------------------------------+

int CountBearishStructure(const SwingPoint &array[],
                          const int endIndex)
  {
   int highs = 0;
   int lows  = 0;

   double previousHigh = 0.0;
   double previousLow  = 0.0;

   bool haveHigh = false;
   bool haveLow  = false;

   int confirmations = 0;

   for(int i=0; i<=endIndex; i++)
     {
      if(array[i].isHigh)
        {
         if(haveHigh && array[i].price < previousHigh)
            highs++;

         previousHigh = array[i].price;
         haveHigh = true;
        }
      else
        {
         if(haveLow && array[i].price < previousLow)
            lows++;

         previousLow = array[i].price;
         haveLow = true;
        }

      if(highs > confirmations &&
         lows > confirmations)
        {
         confirmations++;
        }
     }

   return confirmations;
  }


//+------------------------------------------------------------------+
//| FIND CURRENT HTF STRUCTURE                                       |
//+------------------------------------------------------------------+

int DetermineHistoricalTrend(const SwingPoint &swings[],
                             double &protectedLow,
                             double &protectedHigh,
                             datetime &startTime)
  {
   int count = ArraySize(swings);

   if(count < 4)
      return 0;

   int bullishCount = 0;
   int bearishCount = 0;

   double previousHigh = 0.0;
   double previousLow  = 0.0;

   bool haveHigh = false;
   bool haveLow  = false;

   datetime bullishStart = 0;
   datetime bearishStart = 0;

   int direction = 0;

   protectedLow = 0.0;
   protectedHigh = 0.0;
   startTime = 0;

   for(int i=0; i<count; i++)
     {
      if(swings[i].isHigh)
        {
         if(haveHigh)
           {
            if(swings[i].price > previousHigh)
              {
               bullishCount++;
               bearishCount = 0;

               if(bullishCount >= InpTrendConfirmations &&
                  direction != 1)
                 {
                  direction = 1;
                  bullishStart = swings[i].time;

                  int lowIndex = FindPreviousLow(swings,i);

                  if(lowIndex >= 0)
                     protectedLow = swings[lowIndex].price;

                  protectedHigh = swings[i].price;
                 }
               else
               if(direction == 1)
                 {
                  protectedHigh = swings[i].price;
                 }
              }
            else
            if(swings[i].price < previousHigh)
              {
               bearishCount++;
               bullishCount = 0;

               if(bearishCount >= InpTrendConfirmations &&
                  direction != -1)
                 {
                  direction = -1;
                  bearishStart = swings[i].time;

                  int highIndex = FindPreviousHigh(swings,i);

                  if(highIndex >= 0)
                     protectedHigh = swings[highIndex].price;

                  protectedLow = swings[i].price;
                 }
               else
               if(direction == -1)
                 {
                  protectedLow = swings[i].price;
                 }
              }
           }

         previousHigh = swings[i].price;
         haveHigh = true;
        }
      else
        {
         if(haveLow)
           {
            if(swings[i].price > previousLow)
              {
               bullishCount++;

               if(direction == 1)
                  protectedLow = swings[i].price;
              }
            else
            if(swings[i].price < previousLow)
              {
               bearishCount++;

               if(direction == -1)
                  protectedLow = swings[i].price;
              }
           }

         previousLow = swings[i].price;
         haveLow = true;
        }
     }

   if(direction == 1)
     {
      startTime = bullishStart;
      return 1;
     }

   if(direction == -1)
     {
      startTime = bearishStart;
      return -1;
     }

   return 0;
  }


//+------------------------------------------------------------------+
//| FIND PREVIOUS LOW                                                |
//+------------------------------------------------------------------+

int FindPreviousLow(const SwingPoint &array[],
                    const int index)
  {
   for(int i=index-1; i>=0; i--)
     {
      if(!array[i].isHigh)
         return i;
     }

   return -1;
  }


//+------------------------------------------------------------------+
//| FIND PREVIOUS HIGH                                               |
//+------------------------------------------------------------------+

int FindPreviousHigh(const SwingPoint &array[],
                     const int index)
  {
   for(int i=index-1; i>=0; i--)
     {
      if(array[i].isHigh)
         return i;
     }

   return -1;
  }


//+------------------------------------------------------------------+
//| FIND CURRENT STRUCTURE STATE                                     |
//+------------------------------------------------------------------+

int AnalyzeTrendState()
  {
   int count = ArraySize(g_trendSwings);

   if(count < 4)
      return 0;

   int bullishSequences = 0;
   int bearishSequences = 0;

   double previousHigh = 0.0;
   double previousLow  = 0.0;

   bool haveHigh = false;
   bool haveLow  = false;

   int direction = 0;

   double protectedLow = 0.0;
   double protectedHigh = 0.0;

   datetime directionStart = 0;

   for(int i=0; i<count; i++)
     {
      if(g_trendSwings[i].isHigh)
        {
         if(haveHigh)
           {
            if(g_trendSwings[i].price > previousHigh)
              {
               bullishSequences++;

               if(bearishSequences > 0)
                  bearishSequences = 0;

               if(direction == 1)
                  protectedHigh = g_trendSwings[i].price;
              }
            else
            if(g_trendSwings[i].price < previousHigh)
              {
               bearishSequences++;

               if(bullishSequences > 0)
                  bullishSequences = 0;

               if(direction == -1)
                  protectedLow = g_trendSwings[i].price;
              }
           }

         previousHigh = g_trendSwings[i].price;
         haveHigh = true;
        }
      else
        {
         if(haveLow)
           {
            if(g_trendSwings[i].price > previousLow)
              {
               bullishSequences++;

               if(direction == 1)
                  protectedLow = g_trendSwings[i].price;
              }
            else
            if(g_trendSwings[i].price < previousLow)
              {
               bearishSequences++;

               if(direction == -1)
                  protectedLow = g_trendSwings[i].price;
              }
           }

         previousLow = g_trendSwings[i].price;
         haveLow = true;
        }

      if(bullishSequences >= InpTrendConfirmations)
        {
         if(direction != 1)
           {
            direction = 1;
            directionStart = g_trendSwings[i].time;

            int lowIndex = FindPreviousLow(g_trendSwings,i);

            if(lowIndex >= 0)
               protectedLow = g_trendSwings[lowIndex].price;
           }
        }

      if(bearishSequences >= InpTrendConfirmations)
        {
         if(direction != -1)
           {
            direction = -1;
            directionStart = g_trendSwings[i].time;

            int highIndex = FindPreviousHigh(g_trendSwings,i);

            if(highIndex >= 0)
               protectedHigh = g_trendSwings[highIndex].price;
           }
        }
     }

   if(direction == 1)
     {
      int lastLow = FindLastLow(g_trendSwings);

      if(lastLow >= 0)
         protectedLow = g_trendSwings[lastLow].price;

      int lastHigh = FindLastHigh(g_trendSwings);

      if(lastHigh >= 0)
         protectedHigh = g_trendSwings[lastHigh].price;
     }

   if(direction == -1)
     {
      int lastLow = FindLastLow(g_trendSwings);

      if(lastLow >= 0)
         protectedLow = g_trendSwings[lastLow].price;

      int lastHigh = FindLastHigh(g_trendSwings);

      if(lastHigh >= 0)
         protectedHigh = g_trendSwings[lastHigh].price;
     }

   g_protectedTrendLow  = protectedLow;
   g_protectedTrendHigh = protectedHigh;

   g_trendStartTime = directionStart;

   return direction;
  }


//+------------------------------------------------------------------+
//| GET LAST CLOSED PRICE ON HTF                                     |
//+------------------------------------------------------------------+

double GetLastClosedPrice(ENUM_TIMEFRAMES timeframe)
  {
   MqlRates rates[];

   ArraySetAsSeries(rates,true);

   int copied = CopyRates(_Symbol,
                          timeframe,
                          0,
                          3,
                          rates);

   if(copied < 2)
      return 0.0;

   return rates[1].close;
  }


//+------------------------------------------------------------------+
//| DETECT TREND BREAK                                               |
//+------------------------------------------------------------------+

bool IsLongTrendBroken()
  {
   if(!g_longTrend)
      return false;

   if(g_protectedTrendLow <= 0.0)
      return false;

   double closePrice = GetLastClosedPrice(InpTrendTimeframe);

   if(closePrice <= 0.0)
      return false;

   return closePrice < g_protectedTrendLow;
  }


//+------------------------------------------------------------------+
//| DETECT SHORT TREND BREAK                                         |
//+------------------------------------------------------------------+

bool IsShortTrendBroken()
  {
   if(!g_shortTrend)
      return false;

   if(g_protectedTrendHigh <= 0.0)
      return false;

   double closePrice = GetLastClosedPrice(InpTrendTimeframe);

   if(closePrice <= 0.0)
      return false;

   return closePrice > g_protectedTrendHigh;
  }


//+------------------------------------------------------------------+
//| DRAW TREND OBJECT                                                |
//+------------------------------------------------------------------+

void DrawTrendObject(const int direction,
                     const datetime startTime,
                     const datetime endTime)
  {
   if(!InpDrawTrendObjects)
      return;

   string directionName;

   color objectColor;

   if(direction == 1)
     {
      directionName = "LONG";
      objectColor = InpLongTrendColor;
     }
   else
   if(direction == -1)
     {
      directionName = "SHORT";
      objectColor = InpShortTrendColor;
     }
   else
      return;

   string name = PREFIX_TREND_LINE +
                 directionName + "_" +
                 IntegerToString((long)startTime);

   if(ObjectFind(0,name) >= 0)
      return;

   double price = SymbolInfoDouble(_Symbol,SYMBOL_BID);

   if(price <= 0.0)
      return;

   if(!ObjectCreate(0,
                    name,
                    OBJ_VLINE,
                    0,
                    startTime,
                    0))
      return;

   ObjectSetInteger(0,name,OBJPROP_COLOR,objectColor);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DOT);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);

   if(endTime > startTime)
     {
      string endName = name + "_END";

      if(ObjectFind(0,endName) < 0)
        {
         if(ObjectCreate(0,
                         endName,
                         OBJ_VLINE,
                         0,
                         endTime,
                         0))
           {
            ObjectSetInteger(0,endName,
                             OBJPROP_COLOR,
                             objectColor);

            ObjectSetInteger(0,endName,
                             OBJPROP_STYLE,
                             STYLE_DOT);

            ObjectSetInteger(0,endName,
                             OBJPROP_WIDTH,
                             1);

            ObjectSetInteger(0,endName,
                             OBJPROP_SELECTABLE,
                             false);
           }
        }
     }
  }


//+------------------------------------------------------------------+
//| INITIALIZE TREND STATE                                           |
//+------------------------------------------------------------------+

void InitializeTrendState()
  {
   g_longTrend = false;
   g_shortTrend = false;

   g_trendDirection = 0;

   g_protectedTrendLow = 0.0;
   g_protectedTrendHigh = 0.0;

   int direction = AnalyzeTrendState();

   if(direction == 1)
     {
      g_longTrend = true;
      g_shortTrend = false;
      g_trendDirection = 1;

      DrawTrendObject(1,
                      g_trendStartTime,
                      0);
     }
   else
   if(direction == -1)
     {
      g_longTrend = false;
      g_shortTrend = true;
      g_trendDirection = -1;

      DrawTrendObject(-1,
                      g_trendStartTime,
                      0);
     }
  }


//+------------------------------------------------------------------+
//| GET SIGNAL STRUCTURE                                             |
//+------------------------------------------------------------------+

int GetSignalDirection()
  {
   int count = ArraySize(g_signalSwings);

   if(count < 4)
      return 0;

   int bullish = 0;
   int bearish = 0;

   double previousHigh = 0.0;
   double previousLow  = 0.0;

   bool haveHigh = false;
   bool haveLow  = false;

   for(int i=0; i<count; i++)
     {
      if(g_signalSwings[i].isHigh)
        {
         if(haveHigh)
           {
            if(g_signalSwings[i].price > previousHigh)
               bullish++;
            else
            if(g_signalSwings[i].price < previousHigh)
               bearish++;
           }

         previousHigh = g_signalSwings[i].price;
         haveHigh = true;
        }
      else
        {
         if(haveLow)
           {
            if(g_signalSwings[i].price > previousLow)
               bullish++;
            else
            if(g_signalSwings[i].price < previousLow)
               bearish++;
           }

         previousLow = g_signalSwings[i].price;
         haveLow = true;
        }

      if(bullish >= InpEntryConfirmations &&
         bullish > bearish)
         return 1;

      if(bearish >= InpEntryConfirmations &&
         bearish > bullish)
         return -1;
     }

   return 0;
  }


//+------------------------------------------------------------------+
//| GET MOST RECENT SIGNAL EVENT                                     |
//+------------------------------------------------------------------+

datetime GetSignalEventTime(const int direction)
  {
   int count = ArraySize(g_signalSwings);

   if(count < 2)
      return 0;

   int confirmations = 0;

   double previousHigh = 0.0;
   double previousLow  = 0.0;

   bool haveHigh = false;
   bool haveLow  = false;

   datetime eventTime = 0;

   for(int i=0; i<count; i++)
     {
      if(g_signalSwings[i].isHigh)
        {
         if(haveHigh)
           {
            if(direction == 1 &&
               g_signalSwings[i].price > previousHigh)
               confirmations++;
            else
            if(direction == -1 &&
               g_signalSwings[i].price < previousHigh)
               confirmations++;
           }

         previousHigh = g_signalSwings[i].price;
         haveHigh = true;
        }
      else
        {
         if(haveLow)
           {
            if(direction == 1 &&
               g_signalSwings[i].price > previousLow)
               confirmations++;
            else
            if(direction == -1 &&
               g_signalSwings[i].price < previousLow)
               confirmations++;
           }

         previousLow = g_signalSwings[i].price;
         haveLow = true;
        }

      if(confirmations >= InpEntryConfirmations)
        {
         eventTime = g_signalSwings[i].time;
        }
     }

   return eventTime;
  }


//+------------------------------------------------------------------+
//| COUNT OUR POSITIONS                                              |
//+------------------------------------------------------------------+

int CountOurPositions()
  {
   int count = PositionsTotal();
   int result = 0;

   for(int i=count-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);

      long magic = PositionGetInteger(POSITION_MAGIC);

      if(symbol == _Symbol &&
         (ulong)magic == InpMagicNumber)
         result++;
     }

   return result;
  }


//+------------------------------------------------------------------+
//| GET OUR POSITION TYPE                                            |
//+------------------------------------------------------------------+

int GetOurPositionDirection()
  {
   int count = PositionsTotal();

   for(int i=count-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) !=
         InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
         return 1;

      if(type == POSITION_TYPE_SELL)
         return -1;
     }

   return 0;
  }


//+------------------------------------------------------------------+
//| CLOSE OUR POSITIONS                                              |
//+------------------------------------------------------------------+

bool CloseOurPositions()
  {
   bool success = true;

   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) !=
         InpMagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
        {
         Print("EA13: Failed to close position ",
               ticket,
               ". Retcode=",
               trade.ResultRetcode(),
               " ",
               trade.ResultRetcodeDescription());

         success = false;
        }
     }

   return success;
  }


//+------------------------------------------------------------------+
//| CALCULATE SL PRICE                                               |
//+------------------------------------------------------------------+

double CalculateSLPrice(const int direction,
                        const double entryPrice)
  {
   double sl = 0.0;

   if(InpSLMode == SL_IN_POINTS)
     {
      double distance = InpSLValue * GetPoint();

      if(direction == 1)
         sl = entryPrice - distance;
      else
         sl = entryPrice + distance;
     }
   else
     {
      double distance = entryPrice *
                        InpSLValue /
                        100.0;

      if(direction == 1)
         sl = entryPrice - distance;
      else
         sl = entryPrice + distance;
     }

   return NormalizePrice(sl);
  }


//+------------------------------------------------------------------+
//| CALCULATE TP PRICE                                               |
//+------------------------------------------------------------------+

double CalculateTPPrice(const int direction,
                        const double entryPrice)
  {
   if(InpTPMode == TP_DISABLED)
      return 0.0;

   double tp = 0.0;

   if(InpTPMode == TP_IN_POINTS)
     {
      double distance = InpTPValue * GetPoint();

      if(direction == 1)
         tp = entryPrice + distance;
      else
         tp = entryPrice - distance;
     }
   else
     {
      double distance = entryPrice *
                        InpTPValue /
                        100.0;

      if(direction == 1)
         tp = entryPrice + distance;
      else
         tp = entryPrice - distance;
     }

   return NormalizePrice(tp);
  }


//+------------------------------------------------------------------+
//| MONEY PER LOT FOR STOP                                           |
//+------------------------------------------------------------------+

double CalculateLossPerLot(const int direction,
                           const double entryPrice,
                           const double stopPrice)
  {
   double profit = 0.0;

   ENUM_ORDER_TYPE orderType;

   if(direction == 1)
      orderType = ORDER_TYPE_BUY;
   else
      orderType = ORDER_TYPE_SELL;

   if(!OrderCalcProfit(orderType,
                       _Symbol,
                       1.0,
                       entryPrice,
                       stopPrice,
                       profit))
     {
      Print("EA13: OrderCalcProfit failed. Error=",
            GetLastError());

      return 0.0;
     }

   return MathAbs(profit);
  }


//+------------------------------------------------------------------+
//| NORMALIZE VOLUME                                                 |
//+------------------------------------------------------------------+

double NormalizeVolume(const double volume)
  {
   double minVolume =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   double maxVolume =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);

   double step =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      return 0.0;

   if(volume < minVolume)
      return 0.0;

   double normalized =
      MathFloor(volume / step) * step;

   if(normalized > maxVolume)
      normalized = maxVolume;

   int volumeDigits = 2;

   if(step < 0.01)
      volumeDigits = 3;

   if(step < 0.001)
      volumeDigits = 4;

   return NormalizeDouble(normalized,
                          volumeDigits);
  }


//+------------------------------------------------------------------+
//| CALCULATE LOT SIZE                                               |
//+------------------------------------------------------------------+

double CalculateLotSize(const int direction,
                        const double entryPrice,
                        const double stopPrice)
  {
   if(InpRiskMoney <= 0.0)
      return 0.0;

   double lossPerLot =
      CalculateLossPerLot(direction,
                          entryPrice,
                          stopPrice);

   if(lossPerLot <= 0.0)
      return 0.0;

   double rawVolume =
      InpRiskMoney / lossPerLot;

   return NormalizeVolume(rawVolume);
  }


//+------------------------------------------------------------------+
//| CHECK STOP DISTANCE                                              |
//+------------------------------------------------------------------+

bool ValidateStops(const int direction,
                   const double entry,
                   const double sl,
                   const double tp)
  {
   long stopsLevel =
      SymbolInfoInteger(_Symbol,
                        SYMBOL_TRADE_STOPS_LEVEL);

   double minimumDistance =
      stopsLevel * GetPoint();

   if(direction == 1)
     {
      if(sl >= entry)
         return false;

      if(entry - sl < minimumDistance)
         return false;

      if(tp > 0.0 &&
         tp <= entry)
         return false;

      if(tp > 0.0 &&
         tp - entry < minimumDistance)
         return false;
     }
   else
     {
      if(sl <= entry)
         return false;

      if(sl - entry < minimumDistance)
         return false;

      if(tp > 0.0 &&
         tp >= entry)
         return false;

      if(tp > 0.0 &&
         entry - tp < minimumDistance)
         return false;
     }

   return true;
  }


//+------------------------------------------------------------------+
//| OPEN BUY                                                         |
//+------------------------------------------------------------------+

bool OpenBuy()
  {
   if(!InpAllowBuy)
      return false;

   if(CountOurPositions() > 0)
      return false;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol,tick))
      return false;

   double entryPrice = tick.ask;

   if(entryPrice <= 0.0)
      return false;

   double sl =
      CalculateSLPrice(1,entryPrice);

   double tp =
      CalculateTPPrice(1,entryPrice);

   if(!ValidateStops(1,
                     entryPrice,
                     sl,
                     tp))
     {
      Print("EA13: Invalid BUY SL/TP.");
      return false;
     }

   double volume =
      CalculateLotSize(1,
                       entryPrice,
                       sl);

   if(volume <= 0.0)
     {
      Print("EA13: Calculated BUY volume is below broker minimum "
            "or risk calculation failed.");

      return false;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);

   bool result =
      trade.Buy(volume,
                _Symbol,
                0.0,
                sl,
                tp,
                "EA13 BUY");

   if(!result)
     {
      Print("EA13: BUY failed. Retcode=",
            trade.ResultRetcode(),
            " ",
            trade.ResultRetcodeDescription());

      return false;
     }

   Print("EA13: BUY opened. Volume=",
         DoubleToString(volume,2),
         " SL=",
         DoubleToString(sl,
                        (int)SymbolInfoInteger(_Symbol,
                                               SYMBOL_DIGITS)),
         " TP=",
         DoubleToString(tp,
                        (int)SymbolInfoInteger(_Symbol,
                                               SYMBOL_DIGITS)));

   return true;
  }


//+------------------------------------------------------------------+
//| OPEN SELL                                                        |
//+------------------------------------------------------------------+

bool OpenSell()
  {
   if(!InpAllowSell)
      return false;

   if(CountOurPositions() > 0)
      return false;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol,tick))
      return false;

   double entryPrice = tick.bid;

   if(entryPrice <= 0.0)
      return false;

   double sl =
      CalculateSLPrice(-1,entryPrice);

   double tp =
      CalculateTPPrice(-1,entryPrice);

   if(!ValidateStops(-1,
                     entryPrice,
                     sl,
                     tp))
     {
      Print("EA13: Invalid SELL SL/TP.");
      return false;
     }

   double volume =
      CalculateLotSize(-1,
                       entryPrice,
                       sl);

   if(volume <= 0.0)
     {
      Print("EA13: Calculated SELL volume is below broker minimum "
            "or risk calculation failed.");

      return false;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);

   bool result =
      trade.Sell(volume,
                 _Symbol,
                 0.0,
                 sl,
                 tp,
                 "EA13 SELL");

   if(!result)
     {
      Print("EA13: SELL failed. Retcode=",
            trade.ResultRetcode(),
            " ",
            trade.ResultRetcodeDescription());

      return false;
     }

   Print("EA13: SELL opened. Volume=",
         DoubleToString(volume,2),
         " SL=",
         DoubleToString(sl,
                        (int)SymbolInfoInteger(_Symbol,
                                               SYMBOL_DIGITS)),
         " TP=",
         DoubleToString(tp,
                        (int)SymbolInfoInteger(_Symbol,
                                               SYMBOL_DIGITS)));

   return true;
  }


//+------------------------------------------------------------------+
//| CHECK FOR NEW TREND BAR                                          |
//+------------------------------------------------------------------+

bool IsNewTrendBar()
  {
   datetime currentBar =
      iTime(_Symbol,
            InpTrendTimeframe,
            0);

   if(currentBar <= 0)
      return false;

   if(currentBar != g_lastTrendBarTime)
     {
      g_lastTrendBarTime = currentBar;
      return true;
     }

   return false;
  }


//+------------------------------------------------------------------+
//| CHECK FOR NEW SIGNAL BAR                                         |
//+------------------------------------------------------------------+

bool IsNewSignalBar()
  {
   datetime currentBar =
      iTime(_Symbol,
            InpSignalTimeframe,
            0);

   if(currentBar <= 0)
      return false;

   if(currentBar != g_lastSignalBarTime)
     {
      g_lastSignalBarTime = currentBar;
      return true;
     }

   return false;
  }


//+------------------------------------------------------------------+
//| UPDATE TREND STATE                                               |
//+------------------------------------------------------------------+

void UpdateTrend()
  {
   BuildSwings(InpTrendTimeframe,
               g_trendSwings);

   if(InpDrawTrendSwings)
      DrawSwings(g_trendSwings,true);

   // Existing bullish trend.
   if(g_longTrend)
     {
      if(IsLongTrendBroken())
        {
         g_longTrend = false;
         g_trendDirection = 0;

         g_trendBreakTime =
            iTime(_Symbol,
                  InpTrendTimeframe,
                  1);

         Print("EA13: LONG HTF TREND BROKEN.");

         CloseOurPositions();

         return;
        }
     }

   // Existing bearish trend.
   if(g_shortTrend)
     {
      if(IsShortTrendBroken())
        {
         g_shortTrend = false;
         g_trendDirection = 0;

         g_trendBreakTime =
            iTime(_Symbol,
                  InpTrendTimeframe,
                  1);

         Print("EA13: SHORT HTF TREND BROKEN.");

         CloseOurPositions();

         return;
        }
     }

   int direction = AnalyzeTrendState();

   if(direction == 1)
     {
      if(!g_longTrend)
        {
         g_longTrend = true;
         g_shortTrend = false;
         g_trendDirection = 1;

         Print("EA13: NEW LONG HTF TREND.");

         DrawTrendObject(1,
                         g_trendStartTime,
                         0);
        }
     }
   else
   if(direction == -1)
     {
      if(!g_shortTrend)
        {
         g_shortTrend = true;
         g_longTrend = false;
         g_trendDirection = -1;

         Print("EA13: NEW SHORT HTF TREND.");

         DrawTrendObject(-1,
                         g_trendStartTime,
                         0);
        }
     }
  }


//+------------------------------------------------------------------+
//| UPDATE SIGNAL STRUCTURE                                          |
//+------------------------------------------------------------------+

void UpdateSignalStructure()
  {
   BuildSwings(InpSignalTimeframe,
               g_signalSwings);

   if(InpDrawSignalSwings)
      DrawSwings(g_signalSwings,false);
  }


//+------------------------------------------------------------------+
//| PROCESS ENTRY                                                    |
//+------------------------------------------------------------------+

void ProcessEntry()
  {
   if(CountOurPositions() > 0)
      return;

   int signalDirection =
      GetSignalDirection();

   if(signalDirection == 0)
      return;

   // BUY requires HTF long trend.
   if(signalDirection == 1 &&
      g_longTrend)
     {
      datetime eventTime =
         GetSignalEventTime(1);

      if(eventTime <= 0)
         return;

      if(eventTime == g_lastEntryStructureTime)
         return;

      if(OpenBuy())
        {
         g_lastEntryStructureTime =
            eventTime;
        }

      return;
     }

   // SELL requires HTF short trend.
   if(signalDirection == -1 &&
      g_shortTrend)
     {
      datetime eventTime =
         GetSignalEventTime(-1);

      if(eventTime <= 0)
         return;

      if(eventTime == g_lastEntryStructureTime)
         return;

      if(OpenSell())
        {
         g_lastEntryStructureTime =
            eventTime;
        }

      return;
     }
  }


//+------------------------------------------------------------------+
//| RESET ENTRY EVENT                                                |
//+------------------------------------------------------------------+

void ResetEntryEventIfNecessary()
  {
   if(CountOurPositions() == 0)
     {
      // Do not immediately reset to zero.
      // A new structure must appear before another trade.
     }
  }


//+------------------------------------------------------------------+
//| DISPLAY STATUS                                                   |
//+------------------------------------------------------------------+

void UpdateChartComment()
  {
   string trendText = "NONE";

   if(g_longTrend)
      trendText = "LONG";
   else
   if(g_shortTrend)
      trendText = "SHORT";

   int signalDirection =
      GetSignalDirection();

   string signalText = "NONE";

   if(signalDirection == 1)
      signalText = "BUY";
   else
   if(signalDirection == -1)
      signalText = "SELL";

   string positionText = "NONE";

   int positionDirection =
      GetOurPositionDirection();

   if(positionDirection == 1)
      positionText = "BUY";
   else
   if(positionDirection == -1)
      positionText = "SELL";

   Comment(
      "EA13 - Multi-Timeframe Market Structure\n",
      "Symbol: ",_Symbol,"\n",
      "Trend TF: ",EnumToString(InpTrendTimeframe),"\n",
      "Signal TF: ",EnumToString(InpSignalTimeframe),"\n",
      "HTF Trend: ",trendText,"\n",
      "Signal: ",signalText,"\n",
      "Position: ",positionText,"\n",
      "Protected High: ",
      DoubleToString(g_protectedTrendHigh,
                     (int)SymbolInfoInteger(_Symbol,
                                            SYMBOL_DIGITS)),
      "\n",
      "Protected Low: ",
      DoubleToString(g_protectedTrendLow,
                     (int)SymbolInfoInteger(_Symbol,
                                            SYMBOL_DIGITS))
   );
  }


//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                            |
//+------------------------------------------------------------------+

int OnInit()
  {
   if(!ValidateTimeframes())
      return INIT_FAILED;

   if(InpSwingStrength < 1)
     {
      Print("EA13: SwingStrength must be >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpTrendConfirmations < 1)
     {
      Print("EA13: TrendConfirmations must be >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpEntryConfirmations < 1)
     {
      Print("EA13: EntryConfirmations must be >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpRiskMoney <= 0.0)
     {
      Print("EA13: RiskMoney must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpSLValue <= 0.0)
     {
      Print("EA13: SLValue must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpTPMode != TP_DISABLED &&
      InpTPValue <= 0.0)
     {
      Print("EA13: TPValue must be > 0 when TP is enabled.");
      return INIT_PARAMETERS_INCORRECT;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);

   // Build complete historical structures.
   BuildSwings(InpSignalTimeframe,
               g_signalSwings);

   BuildSwings(InpTrendTimeframe,
               g_trendSwings);

   // Draw permanent swing objects.
   if(InpDrawSignalSwings)
      DrawSwings(g_signalSwings,false);

   if(InpDrawTrendSwings)
      DrawSwings(g_trendSwings,true);

   // Reconstruct trend state from historical data.
   InitializeTrendState();

   // Store current bars so the EA processes future bars only.
   g_lastSignalBarTime =
      iTime(_Symbol,
            InpSignalTimeframe,
            0);

   g_lastTrendBarTime =
      iTime(_Symbol,
            InpTrendTimeframe,
            0);

   Print("==========================================");
   Print("EA13 INITIALIZED");
   Print("Symbol: ",_Symbol);
   Print("Signal TF: ",
         EnumToString(InpSignalTimeframe));
   Print("Trend TF: ",
         EnumToString(InpTrendTimeframe));
   Print("Swing Strength: ",
         InpSwingStrength);
   Print("HTF Confirmations: ",
         InpTrendConfirmations);
   Print("Entry Confirmations: ",
         InpEntryConfirmations);
   Print("Risk Money: ",
         DoubleToString(InpRiskMoney,2));
   Print("==========================================");

   return INIT_SUCCEEDED;
  }


//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                          |
//+------------------------------------------------------------------+

void OnDeinit(const int reason)
  {
   Comment("");

   Print("EA13 deinitialized. Reason=",reason);
  }


//+------------------------------------------------------------------+
//| EXPERT TICK                                                      |
//+------------------------------------------------------------------+

void OnTick()
  {
   // Process higher timeframe changes first.
   if(IsNewTrendBar())
     {
      UpdateTrend();
     }

   // Process signal timeframe changes.
   if(IsNewSignalBar())
     {
      UpdateSignalStructure();

      ProcessEntry();
     }

   UpdateChartComment();
  }


//+------------------------------------------------------------------+
//| TRADE TRANSACTION                                                |
//+------------------------------------------------------------------+

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong dealTicket = trans.deal;

   if(dealTicket == 0)
      return;

   if(!HistoryDealSelect(dealTicket))
      return;

   string symbol =
      HistoryDealGetString(dealTicket,
                           DEAL_SYMBOL);

   if(symbol != _Symbol)
      return;

   long magic =
      HistoryDealGetInteger(dealTicket,
                            DEAL_MAGIC);

   if((ulong)magic != InpMagicNumber)
      return;

   ENUM_DEAL_ENTRY entry =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(
         dealTicket,
         DEAL_ENTRY);

   if(entry == DEAL_ENTRY_OUT)
     {
      Print("EA13: Position closed. Deal=",
            dealTicket);
     }
  }

//+------------------------------------------------------------------+
//| END OF EA13                                                      |
//+------------------------------------------------------------------+