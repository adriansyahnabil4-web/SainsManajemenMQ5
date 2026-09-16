//+------------------------------------------------------------------+
//|                                                    EA18.mq5      |
//| ATR Breakout EA with Advanced Filters                            |
//| Pure MQL5                                                        |
//+------------------------------------------------------------------+
#property strict
#property version   "18.00"
#property description "ATR breakout EA with trend, time, candle, MTF ATR and S/R filters."

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// ENUMS
//====================================================================

enum ENUM_TREND_MODE
{
   TREND_EMA = 0,
   TREND_EMA_SLOPE = 1
};

enum ENUM_ATR_MTF_MODE
{
   ATR_MTF_ABOVE = 0,
   ATR_MTF_BELOW = 1,
   ATR_MTF_RATIO = 2
};

//====================================================================
// GENERAL SETTINGS
//====================================================================

input group "===== GENERAL ====="

input ulong            InpMagicNumber             = 180018;
input ENUM_TIMEFRAMES  InpSignalTimeframe         = PERIOD_CURRENT;
input bool             InpAllowBuy                = true;
input bool             InpAllowSell               = true;

input int              InpMaxPositions            = 1;
input bool             InpOneTradePerBar          = true;

input int              InpDeviationPoints         = 20;

//====================================================================
// RISK MANAGEMENT
//====================================================================

input group "===== RISK MANAGEMENT ====="

input bool             InpUseRiskPercent          = true;
input double           InpRiskPercent             = 1.0;

input double           InpFixedLot                = 0.10;

input double           InpStopLossATR             = 1.5;
input double           InpTakeProfitATR           = 3.0;

input bool             InpUseTakeProfit           = true;

//====================================================================
// ATR BREAKOUT
//====================================================================

input group "===== ATR BREAKOUT ====="

input int              InpATRPeriod               = 14;

input double           InpATRMultiplier            = 0.50;

input int              InpBreakoutLookback         = 20;

input bool             InpUseATRForBreakout        = true;

//====================================================================
// TREND FILTER
//====================================================================

input group "===== TREND FILTER ====="

input bool             InpUseTrendFilter           = true;

input ENUM_TREND_MODE  InpTrendMode               = TREND_EMA;

input int              InpFastEMAPeriod            = 50;
input int              InpSlowEMAPeriod            = 200;

input bool             InpRequirePriceAboveEMA     = true;

//====================================================================
// TIME FILTER
//====================================================================

input group "===== TIME OF DAY FILTER ====="

input bool             InpUseTimeFilter            = true;

input int              InpStartHour                = 7;
input int              InpStartMinute              = 0;

input int              InpEndHour                  = 20;
input int              InpEndMinute                = 0;

//====================================================================
// CANDLE QUALITY
//====================================================================

input group "===== CANDLE QUALITY ====="

input bool             InpUseCandleFilter          = true;

input double           InpMinBodyToWickRatio       = 1.00;

input double           InpMinBodyATRRatio          = 0.20;

//====================================================================
// MULTI TIMEFRAME ATR
//====================================================================

input group "===== MULTI TIMEFRAME ATR ====="

input bool             InpUseMTFATR                = true;

input ENUM_TIMEFRAMES  InpATRHigherTimeframe       = PERIOD_H1;

input int              InpHigherATRPeriod          = 14;

input ENUM_ATR_MTF_MODE InpATRMTFMode              = ATR_MTF_ABOVE;

input double           InpATRRatio                 = 0.80;

//====================================================================
// SUPPORT / RESISTANCE
//====================================================================

input group "===== SUPPORT / RESISTANCE ====="

input bool             InpUseSRFilter              = true;

input int              InpSRLookback               = 50;

input double           InpSRDistanceATR             = 0.50;

input bool             InpUseSwingLevels            = true;

//====================================================================
// TRAILING STOP
//====================================================================

input group "===== TRAILING STOP ====="

input bool             InpUseTrailingStop           = true;

input double           InpTrailingStartATR          = 1.0;

input double           InpTrailingDistanceATR       = 1.0;

input double           InpTrailingStepATR           = 0.25;

//====================================================================
// INTERNAL VARIABLES
//====================================================================

int g_atrHandle       = INVALID_HANDLE;
int g_fastEMAHandle   = INVALID_HANDLE;
int g_slowEMAHandle   = INVALID_HANDLE;
int g_htfATRHandle    = INVALID_HANDLE;

datetime g_lastBarTime = 0;
datetime g_lastTradeBar = 0;

//====================================================================
// HELPER: SIGNAL TIMEFRAME
//====================================================================

ENUM_TIMEFRAMES SignalTF()
{
   if(InpSignalTimeframe == PERIOD_CURRENT)
      return (ENUM_TIMEFRAMES)_Period;

   return InpSignalTimeframe;
}

//====================================================================
// HELPER: NORMALIZE PRICE
//====================================================================

double NormalizePrice(const double price)
{
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

//====================================================================
// HELPER: POINT
//====================================================================

double PointValue()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

//====================================================================
// HELPER: GET INDICATOR VALUE
//====================================================================

bool GetBufferValue(
   const int handle,
   const int buffer,
   const int shift,
   double &value
)
{
   if(handle == INVALID_HANDLE)
      return false;

   double data[];

   ArraySetAsSeries(data, true);

   if(CopyBuffer(handle, buffer, shift, 1, data) != 1)
      return false;

   value = data[0];

   return MathIsValidNumber(value) && value > 0.0;
}

//====================================================================
// GET ATR
//====================================================================

bool GetATR(const int shift, double &atr)
{
   return GetBufferValue(g_atrHandle, 0, shift, atr);
}

//====================================================================
// GET HIGHER TIMEFRAME ATR
//====================================================================

bool GetHigherATR(const int shift, double &atr)
{
   return GetBufferValue(g_htfATRHandle, 0, shift, atr);
}

//====================================================================
// GET EMA
//====================================================================

bool GetFastEMA(const int shift, double &value)
{
   return GetBufferValue(g_fastEMAHandle, 0, shift, value);
}

bool GetSlowEMA(const int shift, double &value)
{
   return GetBufferValue(g_slowEMAHandle, 0, shift, value);
}

//====================================================================
// VALIDATE INPUTS
//====================================================================

bool ValidateInputs()
{
   if(InpMagicNumber == 0)
   {
      Print("EA18: Magic number cannot be zero.");
      return false;
   }

   if(InpATRPeriod < 1)
   {
      Print("EA18: ATR period must be >= 1.");
      return false;
   }

   if(InpBreakoutLookback < 2)
   {
      Print("EA18: Breakout lookback must be >= 2.");
      return false;
   }

   if(InpFastEMAPeriod < 1 || InpSlowEMAPeriod < 1)
   {
      Print("EA18: EMA periods must be >= 1.");
      return false;
   }

   if(InpFastEMAPeriod >= InpSlowEMAPeriod)
   {
      Print("EA18: Fast EMA should be smaller than Slow EMA.");
      return false;
   }

   if(InpRiskPercent <= 0.0)
   {
      Print("EA18: Risk percent must be > 0.");
      return false;
   }

   if(InpFixedLot <= 0.0)
   {
      Print("EA18: Fixed lot must be > 0.");
      return false;
   }

   if(InpStopLossATR <= 0.0)
   {
      Print("EA18: Stop loss ATR multiplier must be > 0.");
      return false;
   }

   if(InpTakeProfitATR <= 0.0)
   {
      Print("EA18: Take profit ATR multiplier must be > 0.");
      return false;
   }

   if(InpATRMultiplier < 0.0)
   {
      Print("EA18: ATR breakout multiplier cannot be negative.");
      return false;
   }

   if(InpMinBodyToWickRatio < 0.0)
   {
      Print("EA18: Body/wick ratio cannot be negative.");
      return false;
   }

   if(InpMinBodyATRRatio < 0.0)
   {
      Print("EA18: Body/ATR ratio cannot be negative.");
      return false;
   }

   if(InpSRLookback < 2)
   {
      Print("EA18: S/R lookback must be >= 2.");
      return false;
   }

   if(InpSRDistanceATR < 0.0)
   {
      Print("EA18: S/R ATR distance cannot be negative.");
      return false;
   }

   if(InpTrailingStartATR <= 0.0)
   {
      Print("EA18: Trailing start ATR must be > 0.");
      return false;
   }

   if(InpTrailingDistanceATR <= 0.0)
   {
      Print("EA18: Trailing distance ATR must be > 0.");
      return false;
   }

   if(InpTrailingStepATR < 0.0)
   {
      Print("EA18: Trailing step ATR cannot be negative.");
      return false;
   }

   if(InpStartHour < 0 || InpStartHour > 23 ||
      InpEndHour < 0 || InpEndHour > 23)
   {
      Print("EA18: Invalid trading hours.");
      return false;
   }

   if(InpStartMinute < 0 || InpStartMinute > 59 ||
      InpEndMinute < 0 || InpEndMinute > 59)
   {
      Print("EA18: Invalid trading minutes.");
      return false;
   }

   return true;
}

//====================================================================
// TIME FILTER
//====================================================================

bool IsTradingTime()
{
   if(!InpUseTimeFilter)
      return true;

   MqlDateTime tm;

   TimeToStruct(TimeCurrent(), tm);

   const int currentMinutes =
      tm.hour * 60 + tm.min;

   const int startMinutes =
      InpStartHour * 60 + InpStartMinute;

   const int endMinutes =
      InpEndHour * 60 + InpEndMinute;

   // Same start/end means 24 hours.
   if(startMinutes == endMinutes)
      return true;

   // Normal intraday range.
   if(startMinutes < endMinutes)
   {
      return currentMinutes >= startMinutes &&
             currentMinutes < endMinutes;
   }

   // Overnight range.
   return currentMinutes >= startMinutes ||
          currentMinutes < endMinutes;
}

//====================================================================
// NEW BAR
//====================================================================

bool IsNewBar()
{
   const ENUM_TIMEFRAMES tf = SignalTF();

   datetime times[];

   ArraySetAsSeries(times, true);

   if(CopyTime(_Symbol, tf, 0, 1, times) != 1)
      return false;

   if(times[0] == g_lastBarTime)
      return false;

   g_lastBarTime = times[0];

   return true;
}

//====================================================================
// COUNT OPEN POSITIONS
//====================================================================

int CountOurPositions()
{
   int count = 0;

   const int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      const string symbol =
         PositionGetString(POSITION_SYMBOL);

      if(symbol != _Symbol)
         continue;

      const ulong magic =
         (ulong)PositionGetInteger(POSITION_MAGIC);

      if(magic != InpMagicNumber)
         continue;

      count++;
   }

   return count;
}

//====================================================================
// FIND OUR POSITION
//====================================================================

bool GetOurPosition(
   ulong &ticket,
   ENUM_POSITION_TYPE &type,
   double &openPrice,
   double &stopLoss,
   double &takeProfit
)
{
   const int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      const ulong posTicket = PositionGetTicket(i);

      if(posTicket == 0)
         continue;

      if(!PositionSelectByTicket(posTicket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ticket = posTicket;

      type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      openPrice =
         PositionGetDouble(POSITION_PRICE_OPEN);

      stopLoss =
         PositionGetDouble(POSITION_SL);

      takeProfit =
         PositionGetDouble(POSITION_TP);

      return true;
   }

   return false;
}

//====================================================================
// HIGHEST HIGH
//====================================================================

bool GetHighestHigh(
   const int startShift,
   const int count,
   double &highest
)
{
   if(count < 1)
      return false;

   const ENUM_TIMEFRAMES tf = SignalTF();

   double highs[];

   ArraySetAsSeries(highs, true);

   const int copied =
      CopyHigh(
         _Symbol,
         tf,
         startShift,
         count,
         highs
      );

   if(copied != count)
      return false;

   highest = highs[0];

   for(int i = 1; i < copied; i++)
   {
      if(highs[i] > highest)
         highest = highs[i];
   }

   return true;
}

//====================================================================
// LOWEST LOW
//====================================================================

bool GetLowestLow(
   const int startShift,
   const int count,
   double &lowest
)
{
   if(count < 1)
      return false;

   const ENUM_TIMEFRAMES tf = SignalTF();

   double lows[];

   ArraySetAsSeries(lows, true);

   const int copied =
      CopyLow(
         _Symbol,
         tf,
         startShift,
         count,
         lows
      );

   if(copied != count)
      return false;

   lowest = lows[0];

   for(int i = 1; i < copied; i++)
   {
      if(lows[i] < lowest)
         lowest = lows[i];
   }

   return true;
}

//====================================================================
// CANDLE QUALITY
//====================================================================

bool CandleQuality(
   const MqlRates &candle,
   const double atr
)
{
   if(!InpUseCandleFilter)
      return true;

   const double body =
      MathAbs(candle.close - candle.open);

   const double upperWick =
      candle.high -
      MathMax(candle.open, candle.close);

   const double lowerWick =
      MathMin(candle.open, candle.close) -
      candle.low;

   const double totalWick =
      upperWick + lowerWick;

   if(body <= 0.0)
      return false;

   if(totalWick > 0.0)
   {
      const double ratio =
         body / totalWick;

      if(ratio < InpMinBodyToWickRatio)
         return false;
   }

   if(atr > 0.0)
   {
      const double bodyATR =
         body / atr;

      if(bodyATR < InpMinBodyATRRatio)
         return false;
   }

   return true;
}

//====================================================================
// TREND FILTER
//====================================================================

bool TrendAllows(
   const bool isBuy,
   const double closePrice
)
{
   if(!InpUseTrendFilter)
      return true;

   double fastEMA = 0.0;
   double slowEMA = 0.0;

   if(!GetFastEMA(1, fastEMA))
      return false;

   if(!GetSlowEMA(1, slowEMA))
      return false;

   if(isBuy)
   {
      if(fastEMA <= slowEMA)
         return false;

      if(InpRequirePriceAboveEMA &&
         closePrice <= fastEMA)
         return false;
   }
   else
   {
      if(fastEMA >= slowEMA)
         return false;

      if(InpRequirePriceAboveEMA &&
         closePrice >= fastEMA)
         return false;
   }

   if(InpTrendMode == TREND_EMA_SLOPE)
   {
      double previousFastEMA = 0.0;
      double previousSlowEMA = 0.0;

      if(!GetFastEMA(2, previousFastEMA))
         return false;

      if(!GetSlowEMA(2, previousSlowEMA))
         return false;

      if(isBuy)
      {
         if(fastEMA <= previousFastEMA)
            return false;

         if(slowEMA < previousSlowEMA)
            return false;
      }
      else
      {
         if(fastEMA >= previousFastEMA)
            return false;

         if(slowEMA > previousSlowEMA)
            return false;
      }
   }

   return true;
}

//====================================================================
// MTF ATR FILTER
//====================================================================

bool MTFATRAllows(const double currentATR)
{
   if(!InpUseMTFATR)
      return true;

   double higherATR = 0.0;

   if(!GetHigherATR(1, higherATR))
      return false;

   if(higherATR <= 0.0)
      return false;

   if(InpATRMTFMode == ATR_MTF_ABOVE)
   {
      return currentATR >= higherATR;
   }

   if(InpATRMTFMode == ATR_MTF_BELOW)
   {
      return currentATR <= higherATR;
   }

   if(InpATRMTFMode == ATR_MTF_RATIO)
   {
      return currentATR >=
             higherATR * InpATRRatio;
   }

   return true;
}

//====================================================================
// SUPPORT / RESISTANCE FILTER
//====================================================================

bool IsNearResistance(
   const double price,
   const double atr
)
{
   if(!InpUseSRFilter)
      return false;

   double resistance = 0.0;

   if(!GetHighestHigh(
      2,
      InpSRLookback,
      resistance))
   {
      return true;
   }

   const double distance =
      resistance - price;

   if(distance < 0.0)
      return true;

   return distance <=
          atr * InpSRDistanceATR;
}

//====================================================================

bool IsNearSupport(
   const double price,
   const double atr
)
{
   if(!InpUseSRFilter)
      return false;

   double support = 0.0;

   if(!GetLowestLow(
      2,
      InpSRLookback,
      support))
   {
      return true;
   }

   const double distance =
      price - support;

   if(distance < 0.0)
      return true;

   return distance <=
          atr * InpSRDistanceATR;
}

//====================================================================
// VOLUME NORMALIZATION
//====================================================================

double NormalizeVolume(const double volume)
{
   const double minVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   const double maxVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );

   const double step =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(step <= 0.0)
      return 0.0;

   double result = volume;

   if(result < minVolume)
      result = minVolume;

   if(result > maxVolume)
      result = maxVolume;

   result =
      MathFloor(result / step) * step;

   if(result < minVolume)
      result = minVolume;

   return NormalizeDouble(result, 8);
}

//====================================================================
// RISK BASED VOLUME
//====================================================================

double CalculateRiskVolume(
   const ENUM_ORDER_TYPE orderType,
   const double entryPrice,
   const double stopPrice
)
{
   if(!InpUseRiskPercent)
      return NormalizeVolume(InpFixedLot);

   const double balance =
      AccountInfoDouble(ACCOUNT_BALANCE);

   if(balance <= 0.0)
      return 0.0;

   const double riskMoney =
      balance * InpRiskPercent / 100.0;

   if(riskMoney <= 0.0)
      return 0.0;

   double profitForOneLot = 0.0;

   if(!OrderCalcProfit(
      orderType,
      _Symbol,
      1.0,
      entryPrice,
      stopPrice,
      profitForOneLot))
   {
      return 0.0;
   }

   const double lossPerLot =
      MathAbs(profitForOneLot);

   if(lossPerLot <= 0.0)
      return 0.0;

   return NormalizeVolume(
      riskMoney / lossPerLot
   );
}

//====================================================================
// MINIMUM STOP DISTANCE
//====================================================================

double MinimumStopDistance()
{
   const long stopsLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   const long freezeLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_FREEZE_LEVEL
      );

   const long level =
      MathMax(stopsLevel, freezeLevel);

   return level * PointValue();
}

//====================================================================
// OPEN BUY
//====================================================================

bool OpenBuy(
   const double atr,
   const datetime signalTime
)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double entry =
      tick.ask;

   double sl =
      entry -
      atr * InpStopLossATR;

   double tp = 0.0;

   if(InpUseTakeProfit)
   {
      tp =
         entry +
         atr * InpTakeProfitATR;
   }

   const double minDistance =
      MinimumStopDistance();

   if(entry - sl < minDistance)
      sl = entry - minDistance;

   if(InpUseTakeProfit &&
      tp - entry < minDistance)
   {
      tp = entry + minDistance;
   }

   sl = NormalizePrice(sl);

   if(InpUseTakeProfit)
      tp = NormalizePrice(tp);

   const double volume =
      CalculateRiskVolume(
         ORDER_TYPE_BUY,
         entry,
         sl
      );

   if(volume <= 0.0)
   {
      Print("EA18: Invalid BUY volume.");
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   const bool result =
      trade.Buy(
         volume,
         _Symbol,
         0.0,
         sl,
         InpUseTakeProfit ? tp : 0.0,
         "EA18 BUY"
      );

   if(!result)
   {
      Print(
         "EA18 BUY failed. Retcode=",
         trade.ResultRetcode(),
         " ",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   g_lastTradeBar = signalTime;

   return true;
}

//====================================================================
// OPEN SELL
//====================================================================

bool OpenSell(
   const double atr,
   const datetime signalTime
)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double entry =
      tick.bid;

   double sl =
      entry +
      atr * InpStopLossATR;

   double tp = 0.0;

   if(InpUseTakeProfit)
   {
      tp =
         entry -
         atr * InpTakeProfitATR;
   }

   const double minDistance =
      MinimumStopDistance();

   if(sl - entry < minDistance)
      sl = entry + minDistance;

   if(InpUseTakeProfit &&
      entry - tp < minDistance)
   {
      tp = entry - minDistance;
   }

   sl = NormalizePrice(sl);

   if(InpUseTakeProfit)
      tp = NormalizePrice(tp);

   const double volume =
      CalculateRiskVolume(
         ORDER_TYPE_SELL,
         entry,
         sl
      );

   if(volume <= 0.0)
   {
      Print("EA18: Invalid SELL volume.");
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   const bool result =
      trade.Sell(
         volume,
         _Symbol,
         0.0,
         sl,
         InpUseTakeProfit ? tp : 0.0,
         "EA18 SELL"
      );

   if(!result)
   {
      Print(
         "EA18 SELL failed. Retcode=",
         trade.ResultRetcode(),
         " ",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   g_lastTradeBar = signalTime;

   return true;
}

//====================================================================
// TRAILING STOP
//====================================================================

void ManageTrailingStop()
{
   if(!InpUseTrailingStop)
      return;

   const int total =
      PositionsTotal();

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double atr = 0.0;

   if(!GetATR(0, atr))
      return;

   const double minDistance =
      MinimumStopDistance();

   for(int i = total - 1; i >= 0; i--)
   {
      const ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC)
         != InpMagicNumber)
      {
         continue;
      }

      const ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)
         PositionGetInteger(POSITION_TYPE);

      const double openPrice =
         PositionGetDouble(POSITION_PRICE_OPEN);

      const double currentSL =
         PositionGetDouble(POSITION_SL);

      const double currentTP =
         PositionGetDouble(POSITION_TP);

      double newSL = currentSL;

      if(type == POSITION_TYPE_BUY)
      {
         const double profitDistance =
            tick.bid - openPrice;

         if(profitDistance <
            atr * InpTrailingStartATR)
         {
            continue;
         }

         newSL =
            tick.bid -
            atr * InpTrailingDistanceATR;

         const double maxAllowed =
            tick.bid - minDistance;

         if(newSL > maxAllowed)
            newSL = maxAllowed;

         newSL = NormalizePrice(newSL);

         if(currentSL > 0.0)
         {
            const double step =
               atr * InpTrailingStepATR;

            if(newSL <= currentSL + step)
               continue;
         }

         if(newSL <= openPrice)
            continue;

         trade.SetExpertMagicNumber(InpMagicNumber);

         if(!trade.PositionModify(
            ticket,
            newSL,
            currentTP))
         {
            Print(
               "EA18: BUY trailing modification failed. ",
               "Ticket=",
               ticket,
               " Retcode=",
               trade.ResultRetcode(),
               " ",
               trade.ResultRetcodeDescription()
            );
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         const double profitDistance =
            openPrice - tick.ask;

         if(profitDistance <
            atr * InpTrailingStartATR)
         {
            continue;
         }

         newSL =
            tick.ask +
            atr * InpTrailingDistanceATR;

         const double minAllowed =
            tick.ask + minDistance;

         if(newSL < minAllowed)
            newSL = minAllowed;

         newSL = NormalizePrice(newSL);

         if(currentSL > 0.0)
         {
            const double step =
               atr * InpTrailingStepATR;

            if(newSL >= currentSL - step)
               continue;
         }

         if(newSL >= openPrice)
            continue;

         trade.SetExpertMagicNumber(InpMagicNumber);

         if(!trade.PositionModify(
            ticket,
            newSL,
            currentTP))
         {
            Print(
               "EA18: SELL trailing modification failed. ",
               "Ticket=",
               ticket,
               " Retcode=",
               trade.ResultRetcode(),
               " ",
               trade.ResultRetcodeDescription()
            );
         }
      }
   }
}

//====================================================================
// SIGNAL PROCESSING
//====================================================================

void ProcessSignal()
{
   if(!IsTradingTime())
      return;

   if(CountOurPositions() >= InpMaxPositions)
      return;

   const ENUM_TIMEFRAMES tf =
      SignalTF();

   MqlRates rates[];

   ArraySetAsSeries(rates, true);

   const int requiredBars =
      MathMax(
         InpBreakoutLookback + 5,
         InpSRLookback + 5
      );

   if(CopyRates(
      _Symbol,
      tf,
      0,
      requiredBars,
      rates
   ) < requiredBars)
   {
      return;
   }

   // ---------------------------------------------------------------
   // Closed signal candle = rates[1]
   // ---------------------------------------------------------------

   const MqlRates signalCandle =
      rates[1];

   const datetime signalTime =
      signalCandle.time;

   if(InpOneTradePerBar &&
      g_lastTradeBar == signalTime)
   {
      return;
   }

   double atr = 0.0;

   if(!GetATR(1, atr))
      return;

   if(atr <= 0.0)
      return;

   // ---------------------------------------------------------------
   // Candle quality filter
   // ---------------------------------------------------------------

   if(!CandleQuality(
      signalCandle,
      atr))
   {
      return;
   }

   // ---------------------------------------------------------------
   // Previous breakout range
   // Start at shift 2 so the signal candle itself is not included.
   // ---------------------------------------------------------------

   double previousHigh = 0.0;
   double previousLow  = 0.0;

   if(!GetHighestHigh(
      2,
      InpBreakoutLookback,
      previousHigh))
   {
      return;
   }

   if(!GetLowestLow(
      2,
      InpBreakoutLookback,
      previousLow))
   {
      return;
   }

   // ---------------------------------------------------------------
   // Breakout levels
   // ---------------------------------------------------------------

   double buyLevel =
      previousHigh;

   double sellLevel =
      previousLow;

   if(InpUseATRForBreakout)
   {
      buyLevel +=
         atr * InpATRMultiplier;

      sellLevel -=
         atr * InpATRMultiplier;
   }

   // ---------------------------------------------------------------
   // BUY SIGNAL
   // ---------------------------------------------------------------

   const bool buyBreakout =
      signalCandle.close > buyLevel;

   if(buyBreakout &&
      InpAllowBuy)
   {
      // Trend confirmation.
      if(!TrendAllows(
         true,
         signalCandle.close))
      {
         return;
      }

      // MTF volatility confirmation.
      if(!MTFATRAllows(atr))
      {
         return;
      }

      // Don't buy directly into resistance.
      if(IsNearResistance(
         signalCandle.close,
         atr))
      {
         return;
      }

      OpenBuy(
         atr,
         signalTime
      );

      return;
   }

   // ---------------------------------------------------------------
   // SELL SIGNAL
   // ---------------------------------------------------------------

   const bool sellBreakout =
      signalCandle.close < sellLevel;

   if(sellBreakout &&
      InpAllowSell)
   {
      // Trend confirmation.
      if(!TrendAllows(
         false,
         signalCandle.close))
      {
         return;
      }

      // MTF volatility confirmation.
      if(!MTFATRAllows(atr))
      {
         return;
      }

      // Don't sell directly into support.
      if(IsNearSupport(
         signalCandle.close,
         atr))
      {
         return;
      }

      OpenSell(
         atr,
         signalTime
      );

      return;
   }
}

//====================================================================
// INITIALIZATION
//====================================================================

int OnInit()
{
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   const ENUM_TIMEFRAMES tf =
      SignalTF();

   // ---------------------------------------------------------------
   // ATR
   // ---------------------------------------------------------------

   g_atrHandle =
      iATR(
         _Symbol,
         tf,
         InpATRPeriod
      );

   if(g_atrHandle == INVALID_HANDLE)
   {
      Print(
         "EA18: Failed to create ATR handle."
      );

      return INIT_FAILED;
   }

   // ---------------------------------------------------------------
   // EMAs
   // ---------------------------------------------------------------

   g_fastEMAHandle =
      iMA(
         _Symbol,
         tf,
         InpFastEMAPeriod,
         0,
         MODE_EMA,
         PRICE_CLOSE
      );

   if(g_fastEMAHandle == INVALID_HANDLE)
   {
      Print(
         "EA18: Failed to create fast EMA handle."
      );

      return INIT_FAILED;
   }

   g_slowEMAHandle =
      iMA(
         _Symbol,
         tf,
         InpSlowEMAPeriod,
         0,
         MODE_EMA,
         PRICE_CLOSE
      );

   if(g_slowEMAHandle == INVALID_HANDLE)
   {
      Print(
         "EA18: Failed to create slow EMA handle."
      );

      return INIT_FAILED;
   }

   // ---------------------------------------------------------------
   // Higher timeframe ATR
   // ---------------------------------------------------------------

   g_htfATRHandle =
      iATR(
         _Symbol,
         InpATRHigherTimeframe,
         InpHigherATRPeriod
      );

   if(g_htfATRHandle == INVALID_HANDLE)
   {
      Print(
         "EA18: Failed to create higher timeframe ATR handle."
      );

      return INIT_FAILED;
   }

   // ---------------------------------------------------------------
   // Trade configuration
   // ---------------------------------------------------------------

   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetDeviationInPoints(
      InpDeviationPoints
   );

   trade.SetTypeFillingBySymbol(
      _Symbol
   );

   Print(
      "EA18 initialized successfully. ",
      "Symbol=",
      _Symbol,
      " TF=",
      EnumToString(tf),
      " Magic=",
      InpMagicNumber
   );

   return INIT_SUCCEEDED;
}

//====================================================================
// DEINITIALIZATION
//====================================================================

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }

   if(g_fastEMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_fastEMAHandle);
      g_fastEMAHandle = INVALID_HANDLE;
   }

   if(g_slowEMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_slowEMAHandle);
      g_slowEMAHandle = INVALID_HANDLE;
   }

   if(g_htfATRHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_htfATRHandle);
      g_htfATRHandle = INVALID_HANDLE;
   }

   Print(
      "EA18 deinitialized. Reason=",
      reason
   );
}

//====================================================================
// TICK
//====================================================================

void OnTick()
{
   // Manage existing positions on every tick.
   ManageTrailingStop();

   // Entries are evaluated only once per new candle.
   if(!IsNewBar())
      return;

   ProcessSignal();
}
//+------------------------------------------------------------------+