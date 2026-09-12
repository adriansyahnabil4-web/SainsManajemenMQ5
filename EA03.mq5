//+------------------------------------------------------------------+
//|                                                      EA03.mq5    |
//|                Swing Breakout Scalping Expert Advisor            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "Scalping breakout EA based on confirmed swing highs/lows."
#property description "Risk-based position sizing with multiple trailing stop methods."

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// ENUMS
//====================================================================

enum ENUM_RISK_MODE
{
   RISK_PERCENT = 0,
   RISK_MONEY   = 1
};

//====================================================================
// INPUT PARAMETERS
//====================================================================

//--------------------------------------------------------------------
// GENERAL SETTINGS
//--------------------------------------------------------------------
input group "=== GENERAL SETTINGS ==="

input ulong            InpMagicNumber        = 20260912;
input ENUM_TIMEFRAMES  InpTimeframe          = PERIOD_M5;
input int              InpDeviationPoints    = 20;

input bool             InpOneTradePerSwing   = true;
input bool             InpOnePositionSymbol  = true;

//--------------------------------------------------------------------
// SWING DETECTION
//--------------------------------------------------------------------
input group "=== SWING DETECTION ==="

input int              InpSwingLeftBars      = 2;
input int              InpSwingRightBars     = 2;
input int              InpMaxLookbackBars    = 500;

//--------------------------------------------------------------------
// STOP LOSS / TAKE PROFIT
//--------------------------------------------------------------------
input group "=== STOP LOSS / TAKE PROFIT ==="

input double           InpStopLossPercent    = 0.20;
input double           InpTakeProfitPercent  = 0.40;

//--------------------------------------------------------------------
// RISK MANAGEMENT
//--------------------------------------------------------------------
input group "=== RISK MANAGEMENT ==="

input ENUM_RISK_MODE   InpRiskMode           = RISK_PERCENT;
input double           InpRiskPercent        = 1.00;
input double           InpRiskMoney          = 100.00;

//--------------------------------------------------------------------
// CLASSICAL TRAILING
//--------------------------------------------------------------------
input group "=== CLASSICAL TRAILING STOP ==="

input bool             InpEnableClassicalTrailing = false;
input double           InpTrailingStartPercent    = 0.10;
input double           InpTrailingDistancePercent = 0.10;
input double           InpTrailingStepPercent     = 0.02;

//--------------------------------------------------------------------
// MOVING AVERAGE TRAILING
//--------------------------------------------------------------------
input group "=== MOVING AVERAGE TRAILING STOP ==="

input bool             InpEnableMATrailing    = false;
input int              InpMAPeriod            = 20;

// IMPORTANT:
// ENUM_MA_METHOD is a BUILT-IN MQL5 enum.
// Do not create another enum with the same name.
input ENUM_MA_METHOD   InpMAMethod            = MODE_EMA;

input ENUM_APPLIED_PRICE InpMAPrice           = PRICE_CLOSE;
input double            InpMAOffsetPercent    = 0.00;

//--------------------------------------------------------------------
// BREAK EVEN
//--------------------------------------------------------------------
input group "=== BREAK-EVEN ==="

input bool             InpEnableBreakEven     = false;
input double           InpBreakEvenTriggerPercent = 0.10;
input double           InpBreakEvenOffsetPercent  = 0.01;

//====================================================================
// GLOBAL VARIABLES
//====================================================================

int      g_maHandle = INVALID_HANDLE;

datetime g_lastBarTime = 0;

datetime g_lastSwingHighTime  = 0;
double   g_lastSwingHighPrice = 0.0;

datetime g_lastSwingLowTime   = 0;
double   g_lastSwingLowPrice  = 0.0;

datetime g_tradedBuySwingTime  = 0;
datetime g_tradedSellSwingTime = 0;

//====================================================================
// STRUCTURE
//====================================================================

struct SwingLevel
{
   bool     found;
   datetime time;
   double   price;
   int      shift;
};

//====================================================================
// GLOBAL VARIABLE NAMES
//====================================================================

string GlobalName(const string suffix)
{
   return "SB_EA_" +
          IntegerToString((long)InpMagicNumber) +
          "_" +
          _Symbol +
          "_" +
          IntegerToString((int)InpTimeframe) +
          "_" +
          suffix;
}

//====================================================================
// PERSISTENT STATE
//====================================================================

void LoadPersistentState()
{
   string name;

   name = GlobalName("BUY_SWING");

   if(GlobalVariableCheck(name))
      g_tradedBuySwingTime =
         (datetime)GlobalVariableGet(name);

   name = GlobalName("SELL_SWING");

   if(GlobalVariableCheck(name))
      g_tradedSellSwingTime =
         (datetime)GlobalVariableGet(name);
}

//--------------------------------------------------------------------

void SaveBuySwingState(const datetime swingTime)
{
   g_tradedBuySwingTime = swingTime;

   GlobalVariableSet(
      GlobalName("BUY_SWING"),
      (double)swingTime
   );
}

//--------------------------------------------------------------------

void SaveSellSwingState(const datetime swingTime)
{
   g_tradedSellSwingTime = swingTime;

   GlobalVariableSet(
      GlobalName("SELL_SWING"),
      (double)swingTime
   );
}

//====================================================================
// PRICE / VOLUME HELPERS
//====================================================================

double NormalizePrice(const double price)
{
   return NormalizeDouble(
      price,
      (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)
   );
}

//--------------------------------------------------------------------

double NormalizeVolume(double volume)
{
   double minVolume =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double maxVolume =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double volumeStep =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(volumeStep <= 0.0)
      return 0.0;

   if(volume < minVolume)
      volume = minVolume;

   if(volume > maxVolume)
      volume = maxVolume;

   volume =
      MathFloor(volume / volumeStep) *
      volumeStep;

   int volumeDigits = 0;

   if(volumeStep < 1.0)
   {
      double step = volumeStep;

      while(step < 1.0 && volumeDigits < 8)
      {
         step *= 10.0;
         volumeDigits++;
      }
   }

   return NormalizeDouble(volume, volumeDigits);
}

//--------------------------------------------------------------------

double GetMinimumStopDistance()
{
   long stopsLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   return (double)stopsLevel * _Point;
}

//--------------------------------------------------------------------

double GetFreezeDistance()
{
   long freezeLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_FREEZE_LEVEL
      );

   return (double)freezeLevel * _Point;
}

//====================================================================
// BAR HANDLING
//====================================================================

bool IsNewBar()
{
   datetime currentBarTime =
      iTime(
         _Symbol,
         InpTimeframe,
         0
      );

   if(currentBarTime <= 0)
      return false;

   if(currentBarTime != g_lastBarTime)
   {
      g_lastBarTime = currentBarTime;
      return true;
   }

   return false;
}

//====================================================================
// SWING HIGH
//====================================================================

bool IsSwingHigh(
   const MqlRates &rates[],
   const int shift,
   const int leftBars,
   const int rightBars
)
{
   int total =
      ArraySize(rates);

   if(shift - rightBars < 0)
      return false;

   if(shift + leftBars >= total)
      return false;

   double candidateHigh =
      rates[shift].high;

   // Right side
   for(int i = 1; i <= rightBars; i++)
   {
      if(rates[shift - i].high >= candidateHigh)
         return false;
   }

   // Left side
   for(int i = 1; i <= leftBars; i++)
   {
      if(rates[shift + i].high >= candidateHigh)
         return false;
   }

   return true;
}

//====================================================================
// SWING LOW
//====================================================================

bool IsSwingLow(
   const MqlRates &rates[],
   const int shift,
   const int leftBars,
   const int rightBars
)
{
   int total =
      ArraySize(rates);

   if(shift - rightBars < 0)
      return false;

   if(shift + leftBars >= total)
      return false;

   double candidateLow =
      rates[shift].low;

   // Right side
   for(int i = 1; i <= rightBars; i++)
   {
      if(rates[shift - i].low <= candidateLow)
         return false;
   }

   // Left side
   for(int i = 1; i <= leftBars; i++)
   {
      if(rates[shift + i].low <= candidateLow)
         return false;
   }

   return true;
}

//====================================================================
// FIND LATEST SWING HIGH
//====================================================================

SwingLevel FindLatestSwingHigh()
{
   SwingLevel result;

   result.found = false;
   result.time  = 0;
   result.price = 0.0;
   result.shift = -1;

   int requiredBars =
      InpMaxLookbackBars +
      InpSwingLeftBars +
      InpSwingRightBars +
      10;

   MqlRates rates[];

   ArraySetAsSeries(rates, true);

   int copied =
      CopyRates(
         _Symbol,
         InpTimeframe,
         0,
         requiredBars,
         rates
      );

   if(copied <= 0)
      return result;

   int firstCandidateShift =
      InpSwingRightBars + 1;

   int lastCandidateShift =
      MathMin(
         copied - InpSwingLeftBars - 1,
         InpMaxLookbackBars
      );

   for(
      int shift = firstCandidateShift;
      shift <= lastCandidateShift;
      shift++
   )
   {
      if(
         IsSwingHigh(
            rates,
            shift,
            InpSwingLeftBars,
            InpSwingRightBars
         )
      )
      {
         result.found = true;
         result.time  = rates[shift].time;
         result.price = rates[shift].high;
         result.shift = shift;

         return result;
      }
   }

   return result;
}

//====================================================================
// FIND LATEST SWING LOW
//====================================================================

SwingLevel FindLatestSwingLow()
{
   SwingLevel result;

   result.found = false;
   result.time  = 0;
   result.price = 0.0;
   result.shift = -1;

   int requiredBars =
      InpMaxLookbackBars +
      InpSwingLeftBars +
      InpSwingRightBars +
      10;

   MqlRates rates[];

   ArraySetAsSeries(rates, true);

   int copied =
      CopyRates(
         _Symbol,
         InpTimeframe,
         0,
         requiredBars,
         rates
      );

   if(copied <= 0)
      return result;

   int firstCandidateShift =
      InpSwingRightBars + 1;

   int lastCandidateShift =
      MathMin(
         copied - InpSwingLeftBars - 1,
         InpMaxLookbackBars
      );

   for(
      int shift = firstCandidateShift;
      shift <= lastCandidateShift;
      shift++
   )
   {
      if(
         IsSwingLow(
            rates,
            shift,
            InpSwingLeftBars,
            InpSwingRightBars
         )
      )
      {
         result.found = true;
         result.time  = rates[shift].time;
         result.price = rates[shift].low;
         result.shift = shift;

         return result;
      }
   }

   return result;
}

//====================================================================
// UPDATE SWINGS
//====================================================================

void UpdateSwingLevels()
{
   SwingLevel high =
      FindLatestSwingHigh();

   SwingLevel low =
      FindLatestSwingLow();

   if(high.found)
   {
      g_lastSwingHighTime =
         high.time;

      g_lastSwingHighPrice =
         high.price;
   }

   if(low.found)
   {
      g_lastSwingLowTime =
         low.time;

      g_lastSwingLowPrice =
         low.price;
   }
}

//====================================================================
// POSITION ISOLATION
//====================================================================

int CountOwnPositions()
{
   int count = 0;

   int total =
      PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol =
         PositionGetString(
            POSITION_SYMBOL
         );

      long magic =
         PositionGetInteger(
            POSITION_MAGIC
         );

      if(
         symbol == _Symbol &&
         (ulong)magic == InpMagicNumber
      )
      {
         count++;
      }
   }

   return count;
}

//--------------------------------------------------------------------

bool HasOwnPosition()
{
   return CountOwnPositions() > 0;
}

//--------------------------------------------------------------------

bool HasForeignPosition()
{
   int total =
      PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol =
         PositionGetString(
            POSITION_SYMBOL
         );

      if(symbol != _Symbol)
         continue;

      long magic =
         PositionGetInteger(
            POSITION_MAGIC
         );

      if((ulong)magic != InpMagicNumber)
         return true;
   }

   return false;
}

//--------------------------------------------------------------------

bool CanOpenPosition()
{
   if(
      InpOnePositionSymbol &&
      HasOwnPosition()
   )
   {
      return false;
   }

   /*
      On netting accounts, avoid opening a position
      when another EA/manual trade already occupies
      this symbol.
   */
   if(HasForeignPosition())
      return false;

   return true;
}

//====================================================================
// RISK MANAGEMENT
//====================================================================

double GetRiskMoney()
{
   if(InpRiskMode == RISK_MONEY)
      return MathMax(
         0.0,
         InpRiskMoney
      );

   double equity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );

   return equity *
          InpRiskPercent /
          100.0;
}

//--------------------------------------------------------------------

double CalculateLotSize(
   const ENUM_ORDER_TYPE orderType,
   const double entryPrice,
   const double stopLossPrice
)
{
   double riskMoney =
      GetRiskMoney();

   if(riskMoney <= 0.0)
      return 0.0;

   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   double tickValueLoss =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_VALUE_LOSS
      );

   if(tickValueLoss <= 0.0)
   {
      tickValueLoss =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_TRADE_TICK_VALUE
         );
   }

   if(
      tickSize <= 0.0 ||
      tickValueLoss <= 0.0
   )
   {
      return 0.0;
   }

   double priceDistance =
      MathAbs(
         entryPrice -
         stopLossPrice
      );

   if(priceDistance <= 0.0)
      return 0.0;

   double lossPerLot =
      (priceDistance / tickSize) *
      tickValueLoss;

   if(lossPerLot <= 0.0)
      return 0.0;

   double volume =
      riskMoney /
      lossPerLot;

   return NormalizeVolume(volume);
}

//====================================================================
// INITIAL SL / TP
//====================================================================

double CalculateInitialSL(
   const ENUM_ORDER_TYPE orderType,
   const double entryPrice
)
{
   if(InpStopLossPercent <= 0.0)
      return 0.0;

   double sl = 0.0;

   if(orderType == ORDER_TYPE_BUY)
   {
      sl =
         entryPrice *
         (
            1.0 -
            InpStopLossPercent / 100.0
         );
   }
   else
   {
      sl =
         entryPrice *
         (
            1.0 +
            InpStopLossPercent / 100.0
         );
   }

   return NormalizePrice(sl);
}

//--------------------------------------------------------------------

double CalculateInitialTP(
   const ENUM_ORDER_TYPE orderType,
   const double entryPrice
)
{
   if(InpTakeProfitPercent <= 0.0)
      return 0.0;

   double tp = 0.0;

   if(orderType == ORDER_TYPE_BUY)
   {
      tp =
         entryPrice *
         (
            1.0 +
            InpTakeProfitPercent / 100.0
         );
   }
   else
   {
      tp =
         entryPrice *
         (
            1.0 -
            InpTakeProfitPercent / 100.0
         );
   }

   return NormalizePrice(tp);
}

//====================================================================
// INITIAL SL VALIDATION
//====================================================================

bool ValidateInitialSL(
   const ENUM_ORDER_TYPE orderType,
   const double entryPrice,
   double &sl
)
{
   if(sl <= 0.0)
      return true;

   double minimumDistance =
      GetMinimumStopDistance();

   if(orderType == ORDER_TYPE_BUY)
   {
      if(
         entryPrice - sl <
         minimumDistance
      )
      {
         sl =
            entryPrice -
            minimumDistance;
      }

      if(sl >= entryPrice)
         return false;
   }
   else
   {
      if(
         sl - entryPrice <
         minimumDistance
      )
      {
         sl =
            entryPrice +
            minimumDistance;
      }

      if(sl <= entryPrice)
         return false;
   }

   sl =
      NormalizePrice(sl);

   return true;
}

//====================================================================
// INITIAL TP VALIDATION
//====================================================================

bool ValidateInitialTP(
   const ENUM_ORDER_TYPE orderType,
   const double entryPrice,
   double &tp
)
{
   if(tp <= 0.0)
      return true;

   double minimumDistance =
      GetMinimumStopDistance();

   if(orderType == ORDER_TYPE_BUY)
   {
      if(
         tp - entryPrice <
         minimumDistance
      )
      {
         tp =
            entryPrice +
            minimumDistance;
      }

      if(tp <= entryPrice)
         return false;
   }
   else
   {
      if(
         entryPrice - tp <
         minimumDistance
      )
      {
         tp =
            entryPrice -
            minimumDistance;
      }

      if(tp >= entryPrice)
         return false;
   }

   tp =
      NormalizePrice(tp);

   return true;
}

//====================================================================
// BREAKOUT
//====================================================================

bool BuyBreakout()
{
   if(g_lastSwingHighPrice <= 0.0)
      return false;

   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      return false;
   }

   return tick.ask >
          g_lastSwingHighPrice;
}

//--------------------------------------------------------------------

bool SellBreakout()
{
   if(g_lastSwingLowPrice <= 0.0)
      return false;

   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      return false;
   }

   return tick.bid <
          g_lastSwingLowPrice;
}

//====================================================================
// OPEN BUY
//====================================================================

bool OpenBuy()
{
   if(!CanOpenPosition())
      return false;

   if(g_lastSwingHighTime <= 0)
      return false;

   if(
      InpOneTradePerSwing &&
      g_tradedBuySwingTime ==
      g_lastSwingHighTime
   )
   {
      return false;
   }

   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      return false;
   }

   double entryPrice =
      tick.ask;

   double sl =
      CalculateInitialSL(
         ORDER_TYPE_BUY,
         entryPrice
      );

   double tp =
      CalculateInitialTP(
         ORDER_TYPE_BUY,
         entryPrice
      );

   if(
      !ValidateInitialSL(
         ORDER_TYPE_BUY,
         entryPrice,
         sl
      )
   )
   {
      Print(
         "BUY rejected: invalid SL."
      );

      return false;
   }

   if(
      !ValidateInitialTP(
         ORDER_TYPE_BUY,
         entryPrice,
         tp
      )
   )
   {
      Print(
         "BUY rejected: invalid TP."
      );

      return false;
   }

   double volume =
      CalculateLotSize(
         ORDER_TYPE_BUY,
         entryPrice,
         sl
      );

   if(volume <= 0.0)
   {
      Print(
         "BUY rejected: invalid calculated volume."
      );

      return false;
   }

   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetDeviationInPoints(
      InpDeviationPoints
   );

   trade.SetTypeFillingBySymbol(
      _Symbol
   );

   bool result =
      trade.Buy(
         volume,
         _Symbol,
         0.0,
         sl,
         tp,
         "SwingBreakout BUY"
      );

   if(!result)
   {
      Print(
         "BUY failed. Retcode=",
         trade.ResultRetcode(),
         " Description=",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   if(InpOneTradePerSwing)
   {
      SaveBuySwingState(
         g_lastSwingHighTime
      );
   }

   Print(
      "BUY opened | Volume=",
      DoubleToString(volume, 2),
      " | Entry=",
      DoubleToString(entryPrice, _Digits),
      " | SL=",
      DoubleToString(sl, _Digits),
      " | TP=",
      DoubleToString(tp, _Digits)
   );

   return true;
}

//====================================================================
// OPEN SELL
//====================================================================

bool OpenSell()
{
   if(!CanOpenPosition())
      return false;

   if(g_lastSwingLowTime <= 0)
      return false;

   if(
      InpOneTradePerSwing &&
      g_tradedSellSwingTime ==
      g_lastSwingLowTime
   )
   {
      return false;
   }

   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      return false;
   }

   double entryPrice =
      tick.bid;

   double sl =
      CalculateInitialSL(
         ORDER_TYPE_SELL,
         entryPrice
      );

   double tp =
      CalculateInitialTP(
         ORDER_TYPE_SELL,
         entryPrice
      );

   if(
      !ValidateInitialSL(
         ORDER_TYPE_SELL,
         entryPrice,
         sl
      )
   )
   {
      Print(
         "SELL rejected: invalid SL."
      );

      return false;
   }

   if(
      !ValidateInitialTP(
         ORDER_TYPE_SELL,
         entryPrice,
         tp
      )
   )
   {
      Print(
         "SELL rejected: invalid TP."
      );

      return false;
   }

   double volume =
      CalculateLotSize(
         ORDER_TYPE_SELL,
         entryPrice,
         sl
      );

   if(volume <= 0.0)
   {
      Print(
         "SELL rejected: invalid calculated volume."
      );

      return false;
   }

   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetDeviationInPoints(
      InpDeviationPoints
   );

   trade.SetTypeFillingBySymbol(
      _Symbol
   );

   bool result =
      trade.Sell(
         volume,
         _Symbol,
         0.0,
         sl,
         tp,
         "SwingBreakout SELL"
      );

   if(!result)
   {
      Print(
         "SELL failed. Retcode=",
         trade.ResultRetcode(),
         " Description=",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   if(InpOneTradePerSwing)
   {
      SaveSellSwingState(
         g_lastSwingLowTime
      );
   }

   Print(
      "SELL opened | Volume=",
      DoubleToString(volume, 2),
      " | Entry=",
      DoubleToString(entryPrice, _Digits),
      " | SL=",
      DoubleToString(sl, _Digits),
      " | TP=",
      DoubleToString(tp, _Digits)
   );

   return true;
}

//====================================================================
// MOVING AVERAGE HANDLE
//====================================================================

bool CreateMAHandle()
{
   if(!InpEnableMATrailing)
      return true;

   g_maHandle =
      iMA(
         _Symbol,
         InpTimeframe,
         InpMAPeriod,
         0,
         InpMAMethod,
         InpMAPrice
      );

   if(g_maHandle == INVALID_HANDLE)
   {
      Print(
         "Failed to create MA handle. Error=",
         GetLastError()
      );

      return false;
   }

   return true;
}

//====================================================================
// GET MA VALUE
//====================================================================

bool GetMAValue(double &value)
{
   if(g_maHandle == INVALID_HANDLE)
      return false;

   double buffer[];

   ArraySetAsSeries(
      buffer,
      true
   );

   int copied =
      CopyBuffer(
         g_maHandle,
         0,
         0,
         1,
         buffer
      );

   if(copied <= 0)
      return false;

   value = buffer[0];

   return value > 0.0;
}

//====================================================================
// CLASSICAL TRAILING
//====================================================================

bool CalculateClassicalTrailing(
   const ENUM_POSITION_TYPE positionType,
   const double entryPrice,
   const double currentPrice,
   double &newSL
)
{
   if(!InpEnableClassicalTrailing)
      return false;

   if(InpTrailingDistancePercent <= 0.0)
      return false;

   double profitPercent = 0.0;

   if(positionType == POSITION_TYPE_BUY)
   {
      profitPercent =
         (
            currentPrice -
            entryPrice
         ) /
         entryPrice *
         100.0;
   }
   else
   {
      profitPercent =
         (
            entryPrice -
            currentPrice
         ) /
         entryPrice *
         100.0;
   }

   if(
      profitPercent <
      InpTrailingStartPercent
   )
   {
      return false;
   }

   if(positionType == POSITION_TYPE_BUY)
   {
      newSL =
         currentPrice *
         (
            1.0 -
            InpTrailingDistancePercent / 100.0
         );
   }
   else
   {
      newSL =
         currentPrice *
         (
            1.0 +
            InpTrailingDistancePercent / 100.0
         );
   }

   newSL =
      NormalizePrice(newSL);

   return true;
}

//====================================================================
// MA TRAILING
//====================================================================

bool CalculateMATrailing(
   const ENUM_POSITION_TYPE positionType,
   double &newSL
)
{
   if(!InpEnableMATrailing)
      return false;

   double maValue = 0.0;

   if(!GetMAValue(maValue))
      return false;

   if(positionType == POSITION_TYPE_BUY)
   {
      newSL =
         maValue *
         (
            1.0 -
            InpMAOffsetPercent / 100.0
         );
   }
   else
   {
      newSL =
         maValue *
         (
            1.0 +
            InpMAOffsetPercent / 100.0
         );
   }

   newSL =
      NormalizePrice(newSL);

   return true;
}

//====================================================================
// BREAK EVEN
//====================================================================

bool CalculateBreakEven(
   const ENUM_POSITION_TYPE positionType,
   const double entryPrice,
   const double currentPrice,
   double &newSL
)
{
   if(!InpEnableBreakEven)
      return false;

   double profitPercent = 0.0;

   if(positionType == POSITION_TYPE_BUY)
   {
      profitPercent =
         (
            currentPrice -
            entryPrice
         ) /
         entryPrice *
         100.0;
   }
   else
   {
      profitPercent =
         (
            entryPrice -
            currentPrice
         ) /
         entryPrice *
         100.0;
   }

   if(
      profitPercent <
      InpBreakEvenTriggerPercent
   )
   {
      return false;
   }

   if(positionType == POSITION_TYPE_BUY)
   {
      newSL =
         entryPrice *
         (
            1.0 +
            InpBreakEvenOffsetPercent / 100.0
         );
   }
   else
   {
      newSL =
         entryPrice *
         (
            1.0 -
            InpBreakEvenOffsetPercent / 100.0
         );
   }

   newSL =
      NormalizePrice(newSL);

   return true;
}

//====================================================================
// TRAILING SL VALIDATION
//====================================================================

bool ValidateBuySL(
   const double proposedSL,
   const double bid
)
{
   if(proposedSL <= 0.0)
      return false;

   double minimumDistance =
      MathMax(
         GetMinimumStopDistance(),
         GetFreezeDistance()
      );

   if(
      bid - proposedSL <
      minimumDistance
   )
   {
      return false;
   }

   if(proposedSL >= bid)
      return false;

   return true;
}

//--------------------------------------------------------------------

bool ValidateSellSL(
   const double proposedSL,
   const double ask
)
{
   if(proposedSL <= 0.0)
      return false;

   double minimumDistance =
      MathMax(
         GetMinimumStopDistance(),
         GetFreezeDistance()
      );

   if(
      proposedSL - ask <
      minimumDistance
   )
   {
      return false;
   }

   if(proposedSL <= ask)
      return false;

   return true;
}

//====================================================================
// POSITION MODIFICATION
//====================================================================

bool ModifyPositionSL(
   const ulong ticket,
   const double newSL,
   const double currentTP
)
{
   if(
      !PositionSelectByTicket(ticket)
   )
   {
      return false;
   }

   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   bool result =
      trade.PositionModify(
         ticket,
         newSL,
         currentTP
      );

   if(!result)
   {
      Print(
         "Position SL modification failed. ",
         "Ticket=",
         ticket,
         " Retcode=",
         trade.ResultRetcode(),
         " Description=",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   return true;
}

//====================================================================
// TRAILING MANAGEMENT
//====================================================================

void ManageTrailingStops()
{
   int total =
      PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(
         !PositionSelectByTicket(ticket)
      )
      {
         continue;
      }

      string symbol =
         PositionGetString(
            POSITION_SYMBOL
         );

      long magic =
         PositionGetInteger(
            POSITION_MAGIC
         );

      if(symbol != _Symbol)
         continue;

      if((ulong)magic != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE positionType =
         (ENUM_POSITION_TYPE)
         PositionGetInteger(
            POSITION_TYPE
         );

      double entryPrice =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );

      double currentSL =
         PositionGetDouble(
            POSITION_SL
         );

      double currentTP =
         PositionGetDouble(
            POSITION_TP
         );

      MqlTick tick;

      if(
         !SymbolInfoTick(
            _Symbol,
            tick
         )
      )
      {
         continue;
      }

      double currentPrice;

      if(positionType == POSITION_TYPE_BUY)
         currentPrice = tick.bid;
      else
         currentPrice = tick.ask;

      //==============================================================
      // Candidate SL
      //==============================================================

      double candidateSL = 0.0;
      bool hasCandidate = false;

      //==============================================================
      // CLASSICAL
      //==============================================================

      double classicalSL = 0.0;

      if(
         CalculateClassicalTrailing(
            positionType,
            entryPrice,
            currentPrice,
            classicalSL
         )
      )
      {
         candidateSL =
            classicalSL;

         hasCandidate = true;
      }

      //==============================================================
      // MA
      //==============================================================

      double maSL = 0.0;

      if(
         CalculateMATrailing(
            positionType,
            maSL
         )
      )
      {
         if(!hasCandidate)
         {
            candidateSL = maSL;
            hasCandidate = true;
         }
         else
         {
            if(positionType == POSITION_TYPE_BUY)
            {
               candidateSL =
                  MathMax(
                     candidateSL,
                     maSL
                  );
            }
            else
            {
               candidateSL =
                  MathMin(
                     candidateSL,
                     maSL
                  );
            }
         }
      }

      //==============================================================
      // BREAK EVEN
      //==============================================================

      double breakEvenSL = 0.0;

      if(
         CalculateBreakEven(
            positionType,
            entryPrice,
            currentPrice,
            breakEvenSL
         )
      )
      {
         if(!hasCandidate)
         {
            candidateSL =
               breakEvenSL;

            hasCandidate = true;
         }
         else
         {
            if(positionType == POSITION_TYPE_BUY)
            {
               candidateSL =
                  MathMax(
                     candidateSL,
                     breakEvenSL
                  );
            }
            else
            {
               candidateSL =
                  MathMin(
                     candidateSL,
                     breakEvenSL
                  );
            }
         }
      }

      if(!hasCandidate)
         continue;

      candidateSL =
         NormalizePrice(candidateSL);

      //==============================================================
      // BUY
      //==============================================================

      if(positionType == POSITION_TYPE_BUY)
      {
         /*
            SL can only move upward.
         */
         if(
            currentSL > 0.0 &&
            candidateSL <= currentSL
         )
         {
            continue;
         }

         /*
            Apply trailing step only if an
            existing SL already exists.
         */
         if(
            currentSL > 0.0 &&
            InpTrailingStepPercent > 0.0
         )
         {
            double minimumImprovement =
               entryPrice *
               InpTrailingStepPercent /
               100.0;

            if(
               candidateSL <
               currentSL +
               minimumImprovement
            )
            {
               continue;
            }
         }

         if(
            !ValidateBuySL(
               candidateSL,
               tick.bid
            )
         )
         {
            continue;
         }

         ModifyPositionSL(
            ticket,
            candidateSL,
            currentTP
         );
      }

      //==============================================================
      // SELL
      //==============================================================

      else if(
         positionType == POSITION_TYPE_SELL
      )
      {
         /*
            SL can only move downward.
         */
         if(
            currentSL > 0.0 &&
            candidateSL >= currentSL
         )
         {
            continue;
         }

         if(
            currentSL > 0.0 &&
            InpTrailingStepPercent > 0.0
         )
         {
            double minimumImprovement =
               entryPrice *
               InpTrailingStepPercent /
               100.0;

            if(
               candidateSL >
               currentSL -
               minimumImprovement
            )
            {
               continue;
            }
         }

         if(
            !ValidateSellSL(
               candidateSL,
               tick.ask
            )
         )
         {
            continue;
         }

         ModifyPositionSL(
            ticket,
            candidateSL,
            currentTP
         );
      }
   }
}

//====================================================================
// INPUT VALIDATION
//====================================================================

bool ValidateInputs()
{
   if(InpMagicNumber == 0)
   {
      Print(
         "Magic number must be greater than zero."
      );

      return false;
   }

   if(InpSwingLeftBars < 1)
   {
      Print(
         "Swing left bars must be >= 1."
      );

      return false;
   }

   if(InpSwingRightBars < 1)
   {
      Print(
         "Swing right bars must be >= 1."
      );

      return false;
   }

   if(
      InpMaxLookbackBars <
      InpSwingLeftBars +
      InpSwingRightBars +
      10
   )
   {
      Print(
         "Max lookback bars is too small."
      );

      return false;
   }

   if(InpStopLossPercent <= 0.0)
   {
      Print(
         "Stop-loss percentage must be > 0."
      );

      return false;
   }

   if(InpTakeProfitPercent < 0.0)
   {
      Print(
         "Take-profit percentage cannot be negative."
      );

      return false;
   }

   if(InpRiskMode == RISK_PERCENT)
   {
      if(InpRiskPercent <= 0.0)
      {
         Print(
            "Risk percentage must be > 0."
         );

         return false;
      }
   }
   else
   {
      if(InpRiskMoney <= 0.0)
      {
         Print(
            "Risk money must be > 0."
         );

         return false;
      }
   }

   if(
      InpEnableMATrailing &&
      InpMAPeriod < 1
   )
   {
      Print(
         "MA period must be >= 1."
      );

      return false;
   }

   if(
      InpEnableClassicalTrailing &&
      InpTrailingDistancePercent <= 0.0
   )
   {
      Print(
         "Classical trailing distance must be > 0."
      );

      return false;
   }

   if(
      InpEnableBreakEven &&
      InpBreakEvenTriggerPercent < 0.0
   )
   {
      Print(
         "Break-even trigger cannot be negative."
      );

      return false;
   }

   return true;
}

//====================================================================
// ON INIT
//====================================================================

int OnInit()
{
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetDeviationInPoints(
      InpDeviationPoints
   );

   trade.SetTypeFillingBySymbol(
      _Symbol
   );

   LoadPersistentState();

   if(!CreateMAHandle())
      return INIT_FAILED;

   g_lastBarTime =
      iTime(
         _Symbol,
         InpTimeframe,
         0
      );

   UpdateSwingLevels();

   Print(
      "================================================"
   );

   Print(
      "EA03 Swing Breakout initialized"
   );

   Print(
      "Symbol: ",
      _Symbol
   );

   Print(
      "Timeframe: ",
      EnumToString(InpTimeframe)
   );

   Print(
      "Magic Number: ",
      InpMagicNumber
   );

   Print(
      "Swing Left: ",
      InpSwingLeftBars
   );

   Print(
      "Swing Right: ",
      InpSwingRightBars
   );

   Print(
      "================================================"
   );

   return INIT_SUCCEEDED;
}

//====================================================================
// ON DEINIT
//====================================================================

void OnDeinit(
   const int reason
)
{
   if(
      g_maHandle != INVALID_HANDLE
   )
   {
      IndicatorRelease(
         g_maHandle
      );

      g_maHandle =
         INVALID_HANDLE;
   }

   Print(
      "EA03 deinitialized. Reason=",
      reason
   );
}

//====================================================================
// ON TICK
//====================================================================

void OnTick()
{
   /*
      Swing levels are updated when
      a new candle appears.
   */
   if(IsNewBar())
   {
      UpdateSwingLevels();
   }

   /*
      Trailing stops are managed
      tick-by-tick.
   */
   ManageTrailingStops();

   /*
      Only one position per symbol.
   */
   if(
      InpOnePositionSymbol &&
      HasOwnPosition()
   )
   {
      return;
   }

   /*
      Never interfere with another
      EA/manual position on symbol.
   */
   if(HasForeignPosition())
      return;

   /*
      BUY breakout.
   */
   if(BuyBreakout())
   {
      OpenBuy();
      return;
   }

   /*
      SELL breakout.
   */
   if(SellBreakout())
   {
      OpenSell();
      return;
   }
}
//+------------------------------------------------------------------+