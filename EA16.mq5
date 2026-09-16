//+------------------------------------------------------------------+
//|                                                     EA16.mq5     |
//|                 ATR Candle Size Strategy - MT5                   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.20"
#property description "ATR candle size strategy for MetaTrader 5"

#include <Trade/Trade.mqh>

CTrade trade;

//--- Strategy
input ulong             InpMagicNumber              = 160016;
input ENUM_TIMEFRAMES   InpTimeframe                = PERIOD_H1;
input int               InpATRPeriod                = 14;
input double            InpATRMultiplier            = 2.0;

//--- Candle close filters
input double            InpBuyCloseDistancePercent  = 25.0;
input double            InpSellCloseDistancePercent = 25.0;

//--- Risk management
input double            InpRiskMoney                = 100.0;
input double            InpStopLossPercent          = 1.0;

//--- Chart information
input bool              InpShowSignalObject         = true;
input color             InpObjectColor              = clrDodgerBlue;
input int               InpObjectFontSize           = 9;
input int               InpObjectOffsetPoints       = 100;

//--- Trading
input int               InpDeviationPoints          = 20;

//--- Globals
int      g_atrHandle   = INVALID_HANDLE;
datetime g_lastBarTime = 0;


//+------------------------------------------------------------------+
//| Normalize price                                                  |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
{
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}


//+------------------------------------------------------------------+
//| Get volume digits                                                |
//+------------------------------------------------------------------+
int GetVolumeDigits(const double step)
{
   if(step <= 0.0)
      return 0;

   int digits = 0;
   double value = step;

   while(digits < 8 && MathAbs(value - MathRound(value)) > 1e-9)
   {
      value *= 10.0;
      digits++;
   }

   return digits;
}


//+------------------------------------------------------------------+
//| Normalize volume                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(const double volume)
{
   const double minVolume =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   const double maxVolume =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   const double volumeStep =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(volume <= 0.0 ||
      volumeStep <= 0.0 ||
      minVolume <= 0.0 ||
      maxVolume <= 0.0)
   {
      return 0.0;
   }

   double normalized =
      MathFloor(volume / volumeStep + 1e-9) * volumeStep;

   if(normalized > maxVolume)
      normalized = maxVolume;

   if(normalized < minVolume)
      return 0.0;

   return NormalizeDouble(
      normalized,
      GetVolumeDigits(volumeStep)
   );
}


//+------------------------------------------------------------------+
//| Calculate volume using OrderCalcProfit                            |
//+------------------------------------------------------------------+
double CalculateRiskVolume(const ENUM_ORDER_TYPE orderType,
                           const double entryPrice,
                           const double stopLossPrice)
{
   if(InpRiskMoney <= 0.0)
      return 0.0;

   if(entryPrice <= 0.0 ||
      stopLossPrice <= 0.0)
   {
      return 0.0;
   }

   double profitForOneLot = 0.0;

   if(!OrderCalcProfit(
         orderType,
         _Symbol,
         1.0,
         entryPrice,
         stopLossPrice,
         profitForOneLot))
   {
      Print(
         "EA16: OrderCalcProfit failed. Error=",
         GetLastError()
      );

      return 0.0;
   }

   const double riskPerLot =
      MathAbs(profitForOneLot);

   if(riskPerLot <= 0.0)
      return 0.0;

   const double rawVolume =
      InpRiskMoney / riskPerLot;

   return NormalizeVolume(rawVolume);
}


//+------------------------------------------------------------------+
//| Check if this candle already generated an entry                  |
//+------------------------------------------------------------------+
bool WasTradeOpenedForCandle(const datetime candleTime)
{
   if(candleTime <= 0)
      return false;

   const datetime now = TimeCurrent();

   if(now < candleTime)
      return false;

   if(!HistorySelect(candleTime, now))
      return false;

   const int total =
      HistoryDealsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      const ulong dealTicket =
         HistoryDealGetTicket(i);

      if(dealTicket == 0)
         continue;

      const string symbol =
         HistoryDealGetString(
            dealTicket,
            DEAL_SYMBOL
         );

      if(symbol != _Symbol)
         continue;

      const ulong magic =
         (ulong)HistoryDealGetInteger(
            dealTicket,
            DEAL_MAGIC
         );

      if(magic != InpMagicNumber)
         continue;

      const ENUM_DEAL_ENTRY entry =
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(
            dealTicket,
            DEAL_ENTRY
         );

      if(entry != DEAL_ENTRY_IN)
         continue;

      const datetime dealTime =
         (datetime)HistoryDealGetInteger(
            dealTicket,
            DEAL_TIME
         );

      if(dealTime >= candleTime)
         return true;
   }

   return false;
}


//+------------------------------------------------------------------+
//| Create signal object                                             |
//+------------------------------------------------------------------+
void CreateSignalObject(const datetime candleTime,
                        const double candleHigh,
                        const double atrValue,
                        const double candleSize,
                        const bool isBuy)
{
   if(!InpShowSignalObject)
      return;

   const string direction =
      isBuy ? "BUY" : "SELL";

   const string objectName =
      "EA16_" +
      IntegerToString((long)candleTime) +
      "_" +
      direction;

   if(ObjectFind(0, objectName) >= 0)
      return;

   const double point =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_POINT
      );

   if(point <= 0.0)
      return;

   const double objectPrice =
      NormalizePrice(
         candleHigh +
         InpObjectOffsetPoints * point
      );

   if(!ObjectCreate(
         0,
         objectName,
         OBJ_TEXT,
         0,
         candleTime,
         objectPrice))
   {
      Print(
         "EA16: ObjectCreate failed. Error=",
         GetLastError()
      );

      return;
   }

   const int digits =
      (int)SymbolInfoInteger(
         _Symbol,
         SYMBOL_DIGITS
      );

   const string text =
      direction +
      "\nATR: " +
      DoubleToString(
         atrValue,
         digits
      ) +
      "\nCandle: " +
      DoubleToString(
         candleSize,
         digits
      );

   ObjectSetString(
      0,
      objectName,
      OBJPROP_TEXT,
      text
   );

   ObjectSetString(
      0,
      objectName,
      OBJPROP_FONT,
      "Arial"
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_FONTSIZE,
      InpObjectFontSize
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_COLOR,
      InpObjectColor
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_ANCHOR,
      ANCHOR_LOWER
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_BACK,
      false
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_SELECTABLE,
      false
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_HIDDEN,
      false
   );

   ChartRedraw(0);
}


//+------------------------------------------------------------------+
//| Validate inputs                                                  |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   if(InpATRPeriod < 1)
   {
      Print("EA16: ATR period must be >= 1.");
      return false;
   }

   if(InpATRMultiplier <= 0.0)
   {
      Print("EA16: ATR multiplier must be > 0.");
      return false;
   }

   if(InpRiskMoney <= 0.0)
   {
      Print("EA16: risk money must be > 0.");
      return false;
   }

   if(InpStopLossPercent <= 0.0)
   {
      Print("EA16: stop loss percent must be > 0.");
      return false;
   }

   if(InpStopLossPercent >= 100.0)
   {
      Print("EA16: stop loss percent must be < 100.");
      return false;
   }

   if(InpBuyCloseDistancePercent < 0.0 ||
      InpBuyCloseDistancePercent > 100.0)
   {
      Print(
         "EA16: buy close distance must be between 0 and 100."
      );

      return false;
   }

   if(InpSellCloseDistancePercent < 0.0 ||
      InpSellCloseDistancePercent > 100.0)
   {
      Print(
         "EA16: sell close distance must be between 0 and 100."
      );

      return false;
   }

   if(InpObjectFontSize < 1)
   {
      Print("EA16: object font size must be >= 1.");
      return false;
   }

   if(InpObjectOffsetPoints < 0)
   {
      Print("EA16: object offset must be >= 0.");
      return false;
   }

   if(InpDeviationPoints < 0)
   {
      Print("EA16: deviation must be >= 0.");
      return false;
   }

   return true;
}


//+------------------------------------------------------------------+
//| Process signal candle                                            |
//+------------------------------------------------------------------+
void ProcessSignal()
{
   const int requiredBars =
      InpATRPeriod + 5;

   if(Bars(_Symbol, InpTimeframe) < requiredBars)
      return;

   //--- Get exactly the candle that just closed.
   //--- Shift 1 = last closed candle.
   MqlRates signalCandle[1];

   const int copiedRates =
      CopyRates(
         _Symbol,
         InpTimeframe,
         1,
         1,
         signalCandle
      );

   if(copiedRates != 1)
      return;

   const datetime signalTime =
      signalCandle[0].time;

   if(signalTime <= 0)
      return;

   //--- Get ATR value for the closed candle.
   double atrBuffer[1];

   const int copiedATR =
      CopyBuffer(
         g_atrHandle,
         0,
         1,
         1,
         atrBuffer
      );

   if(copiedATR != 1)
      return;

   const double atrValue =
      atrBuffer[0];

   if(atrValue <= 0.0)
      return;

   //--- Candle OHLC
   const double candleOpen =
      signalCandle[0].open;

   const double candleHigh =
      signalCandle[0].high;

   const double candleLow =
      signalCandle[0].low;

   const double candleClose =
      signalCandle[0].close;

   const double candleSize =
      candleHigh - candleLow;

   if(candleSize <= 0.0)
      return;

   //--- Candle must be larger than X * ATR.
   if(candleSize <=
      atrValue * InpATRMultiplier)
   {
      return;
   }

   //--- Ignore doji.
   if(candleClose == candleOpen)
      return;

   const bool isBuy =
      candleClose > candleOpen;

   const bool isSell =
      candleClose < candleOpen;

   //--- BUY:
   //--- 0% = close exactly at high.
   //--- 25% = close inside upper 25%.
   //--- 100% = anywhere in candle.
   const double buyCloseDistance =
      ((candleHigh - candleClose) /
       candleSize) * 100.0;

   //--- SELL:
   //--- 0% = close exactly at low.
   //--- 25% = close inside lower 25%.
   //--- 100% = anywhere in candle.
   const double sellCloseDistance =
      ((candleClose - candleLow) /
       candleSize) * 100.0;

   if(isBuy &&
      buyCloseDistance >
      InpBuyCloseDistancePercent)
   {
      return;
   }

   if(isSell &&
      sellCloseDistance >
      InpSellCloseDistancePercent)
   {
      return;
   }

   //--- Only one trade per signal candle.
   if(WasTradeOpenedForCandle(signalTime))
      return;

   //--- Current market price.
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double entryPrice = 0.0;
   double stopLoss = 0.0;

   if(isBuy)
   {
      entryPrice = tick.ask;

      stopLoss =
         entryPrice *
         (1.0 -
          InpStopLossPercent / 100.0);
   }
   else
   {
      entryPrice = tick.bid;

      stopLoss =
         entryPrice *
         (1.0 +
          InpStopLossPercent / 100.0);
   }

   entryPrice =
      NormalizePrice(entryPrice);

   stopLoss =
      NormalizePrice(stopLoss);

   //--- Validate SL direction.
   if(isBuy &&
      stopLoss >= entryPrice)
   {
      return;
   }

   if(isSell &&
      stopLoss <= entryPrice)
   {
      return;
   }

   //--- Broker minimum stop distance.
   const long stopsLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   const double point =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_POINT
      );

   if(point <= 0.0)
      return;

   const double minStopDistance =
      stopsLevel * point;

   if(isBuy &&
      (entryPrice - stopLoss) <
      minStopDistance)
   {
      Print(
         "EA16: BUY skipped - SL is too close."
      );

      return;
   }

   if(isSell &&
      (stopLoss - entryPrice) <
      minStopDistance)
   {
      Print(
         "EA16: SELL skipped - SL is too close."
      );

      return;
   }

   //--- Calculate volume from fixed money risk.
   const ENUM_ORDER_TYPE orderType =
      isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   const double volume =
      CalculateRiskVolume(
         orderType,
         entryPrice,
         stopLoss
      );

   if(volume <= 0.0)
   {
      Print(
         "EA16: trade skipped - calculated volume invalid."
      );

      return;
   }

   //--- Configure trading object.
   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetTypeFillingBySymbol(
      _Symbol
   );

   trade.SetDeviationInPoints(
      InpDeviationPoints
   );

   bool result = false;

   //--- Execute market order.
   if(isBuy)
   {
      result =
         trade.Buy(
            volume,
            _Symbol,
            0.0,
            stopLoss,
            0.0,
            "EA16 ATR BUY"
         );
   }
   else
   {
      result =
         trade.Sell(
            volume,
            _Symbol,
            0.0,
            stopLoss,
            0.0,
            "EA16 ATR SELL"
         );
   }

   if(!result)
   {
      Print(
         "EA16: trade failed. Retcode=",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );

      return;
   }

   const uint retcode =
      trade.ResultRetcode();

   if(retcode != TRADE_RETCODE_DONE &&
      retcode != TRADE_RETCODE_DONE_PARTIAL &&
      retcode != TRADE_RETCODE_PLACED)
   {
      Print(
         "EA16: unexpected trade result. Retcode=",
         retcode,
         " | ",
         trade.ResultRetcodeDescription()
      );

      return;
   }

   //--- Show signal information.
   CreateSignalObject(
      signalTime,
      candleHigh,
      atrValue,
      candleSize,
      isBuy
   );

   const int digits =
      (int)SymbolInfoInteger(
         _Symbol,
         SYMBOL_DIGITS
      );

   const double volumeStep =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   Print(
      "EA16: ",
      isBuy ? "BUY" : "SELL",
      " opened | Volume=",
      DoubleToString(
         volume,
         GetVolumeDigits(volumeStep)
      ),
      " | Entry=",
      DoubleToString(
         entryPrice,
         digits
      ),
      " | SL=",
      DoubleToString(
         stopLoss,
         digits
      ),
      " | ATR=",
      DoubleToString(
         atrValue,
         digits
      ),
      " | CandleSize=",
      DoubleToString(
         candleSize,
         digits
      )
   );
}


//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   //--- Create ATR indicator.
   g_atrHandle =
      iATR(
         _Symbol,
         InpTimeframe,
         InpATRPeriod
      );

   if(g_atrHandle == INVALID_HANDLE)
   {
      Print(
         "EA16: failed to create ATR handle. Error=",
         GetLastError()
      );

      return INIT_FAILED;
   }

   //--- Configure trade object.
   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetTypeFillingBySymbol(
      _Symbol
   );

   trade.SetDeviationInPoints(
      InpDeviationPoints
   );

   //--- Force evaluation on first tick.
   g_lastBarTime = 0;

   Print(
      "EA16 initialized successfully | Symbol=",
      _Symbol,
      " | Timeframe=",
      EnumToString(InpTimeframe),
      " | ATR Period=",
      InpATRPeriod,
      " | ATR Multiplier=",
      DoubleToString(
         InpATRMultiplier,
         2
      )
   );

   return INIT_SUCCEEDED;
}


//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(
         g_atrHandle
      );

      g_atrHandle =
         INVALID_HANDLE;
   }
}


//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(g_atrHandle == INVALID_HANDLE)
      return;

   //--- Current forming candle.
   const datetime currentBarTime =
      iTime(
         _Symbol,
         InpTimeframe,
         0
      );

   if(currentBarTime <= 0)
      return;

   //--- Process only once when a new candle appears.
   if(currentBarTime == g_lastBarTime)
      return;

   g_lastBarTime =
      currentBarTime;

   //--- Process candle that just closed.
   ProcessSignal();
}
//+------------------------------------------------------------------+

