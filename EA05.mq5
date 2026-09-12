//+------------------------------------------------------------------+
//|                                                   EA05.mq5       |
//|                 EURUSD MA 20/60 Crossover EA                     |
//|                         Pure MQL5 / MT5                          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.02"
#property description "EURUSD Moving Average 20/60 Crossover EA"
#property description "Pure MQL5 - MT5 compatible"

#include <Trade/Trade.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

//--- Symbol & Timeframe
input string              InpSymbol           = "EURUSD";
input ENUM_TIMEFRAMES     InpTimeframe        = PERIOD_H1;

//--- Moving Average
input int                 InpFastMAPeriod     = 20;
input int                 InpSlowMAPeriod     = 60;
input ENUM_MA_METHOD      InpMAMethod         = MODE_SMA;
input ENUM_APPLIED_PRICE  InpAppliedPrice     = PRICE_CLOSE;

//--- Trading
input double              InpLotSize          = 0.01;
input int                 InpStopLossPoints   = 500;
input int                 InpTakeProfitPoints = 1000;

//--- Trade Settings
input ulong               InpMagicNumber      = 20260912;
input int                 InpDeviationPoints  = 30;

//--- Position Settings
input bool                InpOnePositionOnly  = true;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+

int      fastMAHandle = INVALID_HANDLE;
int      slowMAHandle = INVALID_HANDLE;
datetime lastBarTime  = 0;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Select EURUSD
   if(!SymbolSelect(InpSymbol, true))
   {
      Print("ERROR: Cannot select symbol ", InpSymbol);
      return INIT_FAILED;
   }

   //--- Validate MA periods
   if(InpFastMAPeriod <= 0 || InpSlowMAPeriod <= 0)
   {
      Print("ERROR: MA periods must be greater than zero.");
      return INIT_FAILED;
   }

   //--- Validate lot size
   if(InpLotSize <= 0)
   {
      Print("ERROR: Lot size must be greater than zero.");
      return INIT_FAILED;
   }

   //--- Create Fast MA
   fastMAHandle = iMA(
      InpSymbol,
      InpTimeframe,
      InpFastMAPeriod,
      0,
      InpMAMethod,
      InpAppliedPrice
   );

   if(fastMAHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Fast MA handle.");
      return INIT_FAILED;
   }

   //--- Create Slow MA
   slowMAHandle = iMA(
      InpSymbol,
      InpTimeframe,
      InpSlowMAPeriod,
      0,
      InpMAMethod,
      InpAppliedPrice
   );

   if(slowMAHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Slow MA handle.");
      return INIT_FAILED;
   }

   //--- Configure trade
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(InpSymbol);

   Print("----------------------------------------");
   Print("EA05 INITIALIZED");
   Print("Symbol       : ", InpSymbol);
   Print("Timeframe    : ", EnumToString(InpTimeframe));
   Print("Fast MA      : ", InpFastMAPeriod);
   Print("Slow MA      : ", InpSlowMAPeriod);
   Print("MA Method    : ", EnumToString(InpMAMethod));
   Print("Lot Size     : ", InpLotSize);
   Print("SL Points    : ", InpStopLossPoints);
   Print("TP Points    : ", InpTakeProfitPoints);
   Print("Magic Number : ", InpMagicNumber);
   Print("----------------------------------------");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(fastMAHandle);
      fastMAHandle = INVALID_HANDLE;
   }

   if(slowMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(slowMAHandle);
      slowMAHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| EXPERT TICK                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Process only once per new candle
   if(!IsNewBar())
      return;

   //--- Make sure enough data exists
   if(BarsCalculated(fastMAHandle) < InpSlowMAPeriod + 2)
      return;

   if(BarsCalculated(slowMAHandle) < InpSlowMAPeriod + 2)
      return;

   //--- Only one position
   if(InpOnePositionOnly && HasOpenPosition())
      return;

   //--- Dynamic arrays
   double fastMA[];
   double slowMA[];

   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);

   //--- Copy Fast MA
   int copiedFast = CopyBuffer(
      fastMAHandle,
      0,
      0,
      3,
      fastMA
   );

   if(copiedFast != 3)
   {
      Print(
         "ERROR: Failed to copy Fast MA data. Copied = ",
         copiedFast
      );
      return;
   }

   //--- Copy Slow MA
   int copiedSlow = CopyBuffer(
      slowMAHandle,
      0,
      0,
      3,
      slowMA
   );

   if(copiedSlow != 3)
   {
      Print(
         "ERROR: Failed to copy Slow MA data. Copied = ",
         copiedSlow
      );
      return;
   }

   //+--------------------------------------------------------------+
   //| [0] = current candle                                         |
   //| [1] = latest closed candle                                   |
   //| [2] = previous closed candle                                 |
   //+--------------------------------------------------------------+

   //--- BUY: MA20 crosses above MA60
   bool bullishCross =
      (fastMA[2] <= slowMA[2]) &&
      (fastMA[1] >  slowMA[1]);

   //--- SELL: MA20 crosses below MA60
   bool bearishCross =
      (fastMA[2] >= slowMA[2]) &&
      (fastMA[1] <  slowMA[1]);

   //--- BUY
   if(bullishCross)
   {
      Print(
         "BUY SIGNAL: MA",
         InpFastMAPeriod,
         " crossed ABOVE MA",
         InpSlowMAPeriod
      );

      OpenBuy();
      return;
   }

   //--- SELL
   if(bearishCross)
   {
      Print(
         "SELL SIGNAL: MA",
         InpFastMAPeriod,
         " crossed BELOW MA",
         InpSlowMAPeriod
      );

      OpenSell();
      return;
   }
}

//+------------------------------------------------------------------+
//| CHECK NEW BAR                                                    |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(
      InpSymbol,
      InpTimeframe,
      0
   );

   if(currentBarTime == 0)
      return false;

   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| CHECK OPEN POSITION                                              |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string positionSymbol =
         PositionGetString(POSITION_SYMBOL);

      ulong positionMagic =
         (ulong)PositionGetInteger(POSITION_MAGIC);

      if(positionSymbol == InpSymbol &&
         positionMagic == InpMagicNumber)
      {
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| NORMALIZE LOT SIZE                                                |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot =
      SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);

   double maxLot =
      SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);

   double lotStep =
      SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0)
      return lot;

   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   lot = MathFloor(lot / lotStep) * lotStep;

   int volumeDigits = 2;

   if(lotStep >= 1.0)
      volumeDigits = 0;
   else if(lotStep >= 0.1)
      volumeDigits = 1;
   else if(lotStep >= 0.01)
      volumeDigits = 2;
   else
      volumeDigits = 3;

   return NormalizeDouble(lot, volumeDigits);
}

//+------------------------------------------------------------------+
//| OPEN BUY                                                         |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask =
      SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

   if(ask <= 0)
   {
      Print("ERROR: Invalid ASK price.");
      return;
   }

   int digits =
      (int)SymbolInfoInteger(
         InpSymbol,
         SYMBOL_DIGITS
      );

   double point =
      SymbolInfoDouble(
         InpSymbol,
         SYMBOL_POINT
      );

   double lot =
      NormalizeLot(InpLotSize);

   double sl = 0.0;
   double tp = 0.0;

   //--- Stop Loss
   if(InpStopLossPoints > 0)
   {
      sl =
         ask -
         (InpStopLossPoints * point);

      sl =
         NormalizeDouble(
            sl,
            digits
         );
   }

   //--- Take Profit
   if(InpTakeProfitPoints > 0)
   {
      tp =
         ask +
         (InpTakeProfitPoints * point);

      tp =
         NormalizeDouble(
            tp,
            digits
         );
   }

   //--- Execute BUY
   bool result =
      trade.Buy(
         lot,
         InpSymbol,
         0.0,
         sl,
         tp,
         "EA05 MA20/60 BUY"
      );

   if(result)
   {
      Print(
         "BUY OPENED | ",
         "Lot=", lot,
         " | Entry=", ask,
         " | SL=", sl,
         " | TP=", tp
      );
   }
   else
   {
      Print(
         "BUY FAILED | Retcode=",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );
   }
}

//+------------------------------------------------------------------+
//| OPEN SELL                                                        |
//+------------------------------------------------------------------+
void OpenSell()
{
   double bid =
      SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   if(bid <= 0)
   {
      Print("ERROR: Invalid BID price.");
      return;
   }

   int digits =
      (int)SymbolInfoInteger(
         InpSymbol,
         SYMBOL_DIGITS
      );

   double point =
      SymbolInfoDouble(
         InpSymbol,
         SYMBOL_POINT
      );

   double lot =
      NormalizeLot(InpLotSize);

   double sl = 0.0;
   double tp = 0.0;

   //--- Stop Loss
   if(InpStopLossPoints > 0)
   {
      sl =
         bid +
         (InpStopLossPoints * point);

      sl =
         NormalizeDouble(
            sl,
            digits
         );
   }

   //--- Take Profit
   if(InpTakeProfitPoints > 0)
   {
      tp =
         bid -
         (InpTakeProfitPoints * point);

      tp =
         NormalizeDouble(
            tp,
            digits
         );
   }

   //--- Execute SELL
   bool result =
      trade.Sell(
         lot,
         InpSymbol,
         0.0,
         sl,
         tp,
         "EA05 MA20/60 SELL"
      );

   if(result)
   {
      Print(
         "SELL OPENED | ",
         "Lot=", lot,
         " | Entry=", bid,
         " | SL=", sl,
         " | TP=", tp
      );
   }
   else
   {
      Print(
         "SELL FAILED | Retcode=",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );
   }
}
//+------------------------------------------------------------------+