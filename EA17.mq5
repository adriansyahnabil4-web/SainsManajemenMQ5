//+------------------------------------------------------------------+
//|                                                     EA17.mq5     |
//|                  MACD Trading Expert Advisor                    |
//|                         Strictly MQL5                            |
//+------------------------------------------------------------------+
#property copyright "EA17"
#property version   "1.01"
#property description "MACD crossover Expert Advisor for MetaTrader 5"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// ENUMS
//====================================================================

enum ENUM_RISK_MODE
  {
   RISK_FIXED_MONEY = 0,
   RISK_PERCENT     = 1
  };

//====================================================================
// INPUTS
//====================================================================

//--- General
input ulong              InpMagicNumber       = 17001;
input ENUM_TIMEFRAMES    InpTimeframe         = PERIOD_H1;

//--- MACD
input int                InpFastMAPeriod      = 12;
input int                InpSlowMAPeriod      = 26;
input int                InpSignalPeriod      = 9;
input ENUM_APPLIED_PRICE InpAppliedPrice      = PRICE_CLOSE;

//--- Zero line filter
input bool               InpUseZeroFilter     = false;

//--- Stop Loss / Take Profit
input double             InpStopLossPercent   = 1.0;
input double             InpTakeProfitPercent = 2.0;

//--- Risk management
input ENUM_RISK_MODE     InpRiskMode          = RISK_PERCENT;
input double             InpRiskMoney         = 100.0;
input double             InpRiskPercent       = 1.0;

//--- Execution
input int                InpDeviationPoints   = 20;

//====================================================================
// GLOBAL VARIABLES
//====================================================================

int      g_macdHandle    = INVALID_HANDLE;
datetime g_lastSignalBar = 0;

//====================================================================
// PRICE NORMALIZATION
//====================================================================

double NormalizePrice(const double price)
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
  }

//====================================================================
// VOLUME NORMALIZATION
//====================================================================

double NormalizeVolume(const double volume)
  {
   double minVolume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(volumeStep <= 0.0)
      return 0.0;

   double normalized = MathFloor(volume / volumeStep) * volumeStep;

   if(normalized < minVolume)
      normalized = minVolume;

   if(normalized > maxVolume)
      normalized = maxVolume;

   int digits = 0;
   double step = volumeStep;

   while(step < 1.0 && digits < 8)
     {
      step *= 10.0;
      digits++;
     }

   return NormalizeDouble(normalized, digits);
  }

//====================================================================
// GET RISK MONEY
//====================================================================

double GetRiskMoney()
  {
   if(InpRiskMode == RISK_FIXED_MONEY)
      return MathMax(0.0, InpRiskMoney);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity <= 0.0)
      return 0.0;

   return equity * InpRiskPercent / 100.0;
  }

//====================================================================
// CALCULATE LOT SIZE
//====================================================================

double CalculateLotSize(const ENUM_ORDER_TYPE orderType,
                        const double entryPrice,
                        const double stopLossPrice)
  {
   double riskMoney = GetRiskMoney();

   if(riskMoney <= 0.0)
      return 0.0;

   double profitForOneLot = 0.0;

   ResetLastError();

   if(!OrderCalcProfit(
         orderType,
         _Symbol,
         1.0,
         entryPrice,
         stopLossPrice,
         profitForOneLot))
     {
      Print("OrderCalcProfit failed. Error: ", GetLastError());
      return 0.0;
     }

   double lossPerLot = MathAbs(profitForOneLot);

   if(lossPerLot <= 0.0)
      return 0.0;

   double rawVolume = riskMoney / lossPerLot;

   return NormalizeVolume(rawVolume);
  }

//====================================================================
// CHECK BROKER STOP DISTANCE
//====================================================================

bool IsValidStopDistance(const double entryPrice,
                         const double stopLoss,
                         const double takeProfit,
                         const ENUM_ORDER_TYPE orderType)
  {
   long stopsLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   long freezeLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   long requiredLevel = MathMax(stopsLevel, freezeLevel);

   if(requiredLevel <= 0)
      return true;

   double point =
      SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double minimumDistance =
      requiredLevel * point;

   if(orderType == ORDER_TYPE_BUY)
     {
      if((entryPrice - stopLoss) < minimumDistance)
         return false;

      if((takeProfit - entryPrice) < minimumDistance)
         return false;
     }
   else
   if(orderType == ORDER_TYPE_SELL)
     {
      if((stopLoss - entryPrice) < minimumDistance)
         return false;

      if((entryPrice - takeProfit) < minimumDistance)
         return false;
     }

   return true;
  }

//====================================================================
// CHECK FOR OUR POSITION
//====================================================================

bool HasOurPosition(ENUM_POSITION_TYPE &positionType)
  {
   positionType = WRONG_VALUE;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol =
         PositionGetString(POSITION_SYMBOL);

      ulong magic =
         (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol != _Symbol)
         continue;

      if(magic != InpMagicNumber)
         continue;

      positionType =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      return true;
     }

   return false;
  }

//====================================================================
// CHECK FOR FOREIGN POSITION
//====================================================================

bool HasForeignPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol =
         PositionGetString(POSITION_SYMBOL);

      ulong magic =
         (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol != _Symbol)
         continue;

      if(magic == InpMagicNumber)
         continue;

      return true;
     }

   return false;
  }

//====================================================================
// CHECK ACCOUNT TYPE
//====================================================================

bool IsHedgingAccount()
  {
   ENUM_ACCOUNT_MARGIN_MODE mode =
      (ENUM_ACCOUNT_MARGIN_MODE)
      AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
  }

//====================================================================
// CLOSE OUR POSITIONS
//====================================================================

bool CloseOurPositions()
  {
   bool success = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol =
         PositionGetString(POSITION_SYMBOL);

      ulong magic =
         (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol != _Symbol)
         continue;

      if(magic != InpMagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
        {
         Print(
            "Failed to close position #",
            ticket,
            ". Retcode: ",
            trade.ResultRetcode(),
            " - ",
            trade.ResultRetcodeDescription()
            );

         success = false;
        }
     }

   return success;
  }

//====================================================================
// OPEN BUY
//====================================================================

bool OpenBuy()
  {
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
     {
      Print("Failed to get market tick.");
      return false;
     }

   double entryPrice = tick.ask;

   if(entryPrice <= 0.0)
      return false;

   double stopLoss =
      entryPrice *
      (1.0 - InpStopLossPercent / 100.0);

   double takeProfit =
      entryPrice *
      (1.0 + InpTakeProfitPercent / 100.0);

   stopLoss   = NormalizePrice(stopLoss);
   takeProfit = NormalizePrice(takeProfit);

   if(stopLoss <= 0.0)
      return false;

   if(takeProfit <= entryPrice)
      return false;

   if(!IsValidStopDistance(
         entryPrice,
         stopLoss,
         takeProfit,
         ORDER_TYPE_BUY))
     {
      Print("BUY SL/TP distance is below broker minimum.");
      return false;
     }

   double volume =
      CalculateLotSize(
         ORDER_TYPE_BUY,
         entryPrice,
         stopLoss);

   if(volume <= 0.0)
     {
      Print("Calculated BUY volume is invalid.");
      return false;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool result =
      trade.Buy(
         volume,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         "EA17 MACD BUY"
         );

   if(!result)
     {
      Print(
         "BUY failed. Retcode: ",
         trade.ResultRetcode(),
         " - ",
         trade.ResultRetcodeDescription()
         );

      return false;
     }

   Print(
      "EA17 BUY opened | Volume: ",
      DoubleToString(volume, 2),
      " | Entry: ",
      DoubleToString(entryPrice,
                     (int)SymbolInfoInteger(
                        _Symbol,
                        SYMBOL_DIGITS)),
      " | SL: ",
      DoubleToString(stopLoss,
                     (int)SymbolInfoInteger(
                        _Symbol,
                        SYMBOL_DIGITS)),
      " | TP: ",
      DoubleToString(takeProfit,
                     (int)SymbolInfoInteger(
                        _Symbol,
                        SYMBOL_DIGITS))
      );

   return true;
  }

//====================================================================
// OPEN SELL
//====================================================================

bool OpenSell()
  {
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
     {
      Print("Failed to get market tick.");
      return false;
     }

   double entryPrice = tick.bid;

   if(entryPrice <= 0.0)
      return false;

   double stopLoss =
      entryPrice *
      (1.0 + InpStopLossPercent / 100.0);

   double takeProfit =
      entryPrice *
      (1.0 - InpTakeProfitPercent / 100.0);

   stopLoss   = NormalizePrice(stopLoss);
   takeProfit = NormalizePrice(takeProfit);

   if(takeProfit <= 0.0)
      return false;

   if(stopLoss <= entryPrice)
      return false;

   if(!IsValidStopDistance(
         entryPrice,
         stopLoss,
         takeProfit,
         ORDER_TYPE_SELL))
     {
      Print("SELL SL/TP distance is below broker minimum.");
      return false;
     }

   double volume =
      CalculateLotSize(
         ORDER_TYPE_SELL,
         entryPrice,
         stopLoss);

   if(volume <= 0.0)
     {
      Print("Calculated SELL volume is invalid.");
      return false;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool result =
      trade.Sell(
         volume,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         "EA17 MACD SELL"
         );

   if(!result)
     {
      Print(
         "SELL failed. Retcode: ",
         trade.ResultRetcode(),
         " - ",
         trade.ResultRetcodeDescription()
         );

      return false;
     }

   Print(
      "EA17 SELL opened | Volume: ",
      DoubleToString(volume, 2),
      " | Entry: ",
      DoubleToString(entryPrice,
                     (int)SymbolInfoInteger(
                        _Symbol,
                        SYMBOL_DIGITS)),
      " | SL: ",
      DoubleToString(stopLoss,
                     (int)SymbolInfoInteger(
                        _Symbol,
                        SYMBOL_DIGITS)),
      " | TP: ",
      DoubleToString(takeProfit,
                     (int)SymbolInfoInteger(
                        _Symbol,
                        SYMBOL_DIGITS))
      );

   return true;
  }

//====================================================================
// GET MACD SIGNAL
//
//  1  = BUY
// -1  = SELL
//  0  = NONE
//
// Uses:
// [1] = latest closed candle
// [2] = candle before latest closed candle
//====================================================================

int GetMACDSignal()
  {
   if(g_macdHandle == INVALID_HANDLE)
      return 0;

   // Dynamic arrays are required because
   // ArraySetAsSeries() cannot be used with static arrays.
   double macdMain[];
   double macdSignal[];

   ArrayResize(macdMain, 3);
   ArrayResize(macdSignal, 3);

   ArraySetAsSeries(macdMain, true);
   ArraySetAsSeries(macdSignal, true);

   int copiedMain =
      CopyBuffer(
         g_macdHandle,
         0,
         0,
         3,
         macdMain);

   if(copiedMain < 3)
      return 0;

   int copiedSignal =
      CopyBuffer(
         g_macdHandle,
         1,
         0,
         3,
         macdSignal);

   if(copiedSignal < 3)
      return 0;

   double mainCurrent =
      macdMain[1];

   double signalCurrent =
      macdSignal[1];

   double mainPrevious =
      macdMain[2];

   double signalPrevious =
      macdSignal[2];

   //===============================================================
   // BULLISH CROSS
   //===============================================================

   bool bullishCross =
      (mainPrevious <= signalPrevious &&
       mainCurrent  >  signalCurrent);

   if(bullishCross)
     {
      // BUY only below zero when filter is enabled.
      if(InpUseZeroFilter &&
         mainCurrent >= 0.0)
         return 0;

      return 1;
     }

   //===============================================================
   // BEARISH CROSS
   //===============================================================

   bool bearishCross =
      (mainPrevious >= signalPrevious &&
       mainCurrent  <  signalCurrent);

   if(bearishCross)
     {
      // SELL only above zero when filter is enabled.
      if(InpUseZeroFilter &&
         mainCurrent <= 0.0)
         return 0;

      return -1;
     }

   return 0;
  }

//====================================================================
// PROCESS SIGNAL
//====================================================================

void ProcessSignal(const int signal)
  {
   if(signal == 0)
      return;

   // In netting accounts, MT5 allows only one net position
   // per symbol. Therefore avoid touching a symbol that has
   // another EA/manual position.
   if(!IsHedgingAccount())
     {
      if(HasForeignPosition())
        {
         Print(
            "EA17 skipped signal because another position "
            "exists on ",
            _Symbol,
            " in netting mode."
            );

         return;
        }
     }

   ENUM_POSITION_TYPE currentType;

   bool hasPosition =
      HasOurPosition(currentType);

   //===============================================================
   // BUY SIGNAL
   //===============================================================

   if(signal > 0)
     {
      // Already BUY.
      if(hasPosition &&
         currentType == POSITION_TYPE_BUY)
         return;

      // Reverse SELL -> BUY.
      if(hasPosition &&
         currentType == POSITION_TYPE_SELL)
        {
         if(!CloseOurPositions())
            return;

         ENUM_POSITION_TYPE checkType;

         if(HasOurPosition(checkType))
            return;
        }

      OpenBuy();

      return;
     }

   //===============================================================
   // SELL SIGNAL
   //===============================================================

   if(signal < 0)
     {
      // Already SELL.
      if(hasPosition &&
         currentType == POSITION_TYPE_SELL)
         return;

      // Reverse BUY -> SELL.
      if(hasPosition &&
         currentType == POSITION_TYPE_BUY)
        {
         if(!CloseOurPositions())
            return;

         ENUM_POSITION_TYPE checkType;

         if(HasOurPosition(checkType))
            return;
        }

      OpenSell();

      return;
     }
  }

//====================================================================
// INITIALIZATION
//====================================================================

int OnInit()
  {
   //===============================================================
   // VALIDATE INPUTS
   //===============================================================

   if(InpFastMAPeriod <= 0)
     {
      Print("Invalid Fast MA period.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpSlowMAPeriod <= 0)
     {
      Print("Invalid Slow MA period.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpSignalPeriod <= 0)
     {
      Print("Invalid Signal period.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpFastMAPeriod >= InpSlowMAPeriod)
     {
      Print(
         "Fast MA period must be smaller than "
         "Slow MA period."
         );

      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpStopLossPercent <= 0.0)
     {
      Print("Stop Loss percentage must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpTakeProfitPercent <= 0.0)
     {
      Print("Take Profit percentage must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpRiskMode == RISK_FIXED_MONEY)
     {
      if(InpRiskMoney <= 0.0)
        {
         Print("Fixed risk amount must be greater than zero.");
         return INIT_PARAMETERS_INCORRECT;
        }
     }

   if(InpRiskMode == RISK_PERCENT)
     {
      if(InpRiskPercent <= 0.0)
        {
         Print("Risk percentage must be greater than zero.");
         return INIT_PARAMETERS_INCORRECT;
        }
     }

   //===============================================================
   // CREATE MACD HANDLE
   //===============================================================

   g_macdHandle =
      iMACD(
         _Symbol,
         InpTimeframe,
         InpFastMAPeriod,
         InpSlowMAPeriod,
         InpSignalPeriod,
         InpAppliedPrice
         );

   if(g_macdHandle == INVALID_HANDLE)
     {
      Print(
         "Failed to create MACD handle. Error: ",
         GetLastError()
         );

      return INIT_FAILED;
     }

   //===============================================================
   // TRADE CONFIGURATION
   //===============================================================

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   //===============================================================
   // INITIALIZE LAST PROCESSED BAR
   //
   // This prevents an old crossover from immediately firing when
   // the EA is attached or MT5 is restarted.
   //===============================================================

   datetime timeBuffer[];

   ArrayResize(timeBuffer, 1);
   ArraySetAsSeries(timeBuffer, true);

   if(CopyTime(
         _Symbol,
         InpTimeframe,
         1,
         1,
         timeBuffer) == 1)
     {
      g_lastSignalBar = timeBuffer[0];
     }

   //===============================================================
   // LOG
   //===============================================================

   Print("==============================================");
   Print("EA17 initialized successfully.");
   Print("Symbol: ", _Symbol);
   Print("Timeframe: ", EnumToString(InpTimeframe));
   Print("Magic Number: ", InpMagicNumber);

   Print(
      "MACD: ",
      InpFastMAPeriod,
      "/",
      InpSlowMAPeriod,
      "/",
      InpSignalPeriod
      );

   Print(
      "Zero Filter: ",
      InpUseZeroFilter ? "ON" : "OFF"
      );

   Print(
      "Stop Loss: ",
      DoubleToString(InpStopLossPercent, 4),
      "%"
      );

   Print(
      "Take Profit: ",
      DoubleToString(InpTakeProfitPercent, 4),
      "%"
      );

   if(InpRiskMode == RISK_FIXED_MONEY)
     {
      Print(
         "Risk Mode: FIXED MONEY | Amount: ",
         DoubleToString(InpRiskMoney, 2)
         );
     }
   else
     {
      Print(
         "Risk Mode: EQUITY PERCENT | Risk: ",
         DoubleToString(InpRiskPercent, 2),
         "%"
         );
     }

   Print("==============================================");

   return INIT_SUCCEEDED;
  }

//====================================================================
// DEINITIALIZATION
//====================================================================

void OnDeinit(const int reason)
  {
   if(g_macdHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_macdHandle);
      g_macdHandle = INVALID_HANDLE;
     }
  }

//====================================================================
// ON TICK
//====================================================================

void OnTick()
  {
   if(g_macdHandle == INVALID_HANDLE)
      return;

   //===============================================================
   // GET LATEST CLOSED CANDLE TIME
   //===============================================================

   datetime timeBuffer[];

   ArrayResize(timeBuffer, 1);
   ArraySetAsSeries(timeBuffer, true);

   if(CopyTime(
         _Symbol,
         InpTimeframe,
         1,
         1,
         timeBuffer) != 1)
      return;

   datetime currentClosedBar =
      timeBuffer[0];

   if(currentClosedBar <= 0)
      return;

   //===============================================================
   // PROCESS ONLY ONCE PER NEW CLOSED CANDLE
   //===============================================================

   if(currentClosedBar == g_lastSignalBar)
      return;

   g_lastSignalBar =
      currentClosedBar;

   //===============================================================
   // GET MACD SIGNAL
   //===============================================================

   int signal =
      GetMACDSignal();

   if(signal == 0)
      return;

   //===============================================================
   // PROCESS
   //===============================================================

   ProcessSignal(signal);
  }

//+------------------------------------------------------------------+