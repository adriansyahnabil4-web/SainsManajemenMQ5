//+------------------------------------------------------------------+
//|                                                   EA12.mq5       |
//|                    RSI + Risk Management + Trailing Stop         |
//|                         Pure MQL5 / MT5                           |
//+------------------------------------------------------------------+
#property strict
#property version   "1.01"
#property description "RSI-based Expert Advisor with risk management and trailing stop."
#property description "Pure MQL5 - no deprecated MQL4 functions."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Trading object                                                   |
//+------------------------------------------------------------------+
CTrade trade;

//+------------------------------------------------------------------+
//| Risk mode                                                         |
//+------------------------------------------------------------------+
enum ENUM_RISK_MODE
  {
   RISK_FIXED_LOT = 0,
   RISK_PERCENT_BALANCE = 1
  };

//+------------------------------------------------------------------+
//| GENERAL SETTINGS                                                  |
//+------------------------------------------------------------------+
input group "=== GENERAL SETTINGS ==="

input ulong
   InpMagicNumber = 12001;

input string
   InpTradeComment = "EA12 RSI";

input bool
   InpAllowBuy = true;

input bool
   InpAllowSell = true;

input bool
   InpOnePositionOnly = true;

//+------------------------------------------------------------------+
//| RSI SETTINGS                                                      |
//+------------------------------------------------------------------+
input group "=== RSI SETTINGS ==="

input ENUM_TIMEFRAMES
   InpRSITimeframe = PERIOD_CURRENT;

input int
   InpRSIPeriod = 14;

input ENUM_APPLIED_PRICE
   InpRSIPrice = PRICE_CLOSE;

input double
   InpBuyRSILevel = 30.0;

input double
   InpSellRSILevel = 70.0;

//+------------------------------------------------------------------+
//| RISK MANAGEMENT                                                  |
//+------------------------------------------------------------------+
input group "=== RISK MANAGEMENT ==="

input ENUM_RISK_MODE
   InpRiskMode = RISK_PERCENT_BALANCE;

input double
   InpFixedLot = 0.01;

input double
   InpRiskPercent = 1.0;

//+------------------------------------------------------------------+
//| STOP LOSS / TAKE PROFIT                                           |
//+------------------------------------------------------------------+
input group "=== SL / TP SETTINGS ==="

input bool
   InpUseStopLoss = true;

input double
   InpStopLossPoints = 500.0;

input bool
   InpUseTakeProfit = true;

input double
   InpTakeProfitPoints = 1000.0;

//+------------------------------------------------------------------+
//| TRAILING STOP                                                     |
//+------------------------------------------------------------------+
input group "=== TRAILING STOP SETTINGS ==="

input bool
   InpUseTrailingStop = true;

input double
   InpTrailingStart = 500.0;

input double
   InpTrailingDistance = 300.0;

input double
   InpTrailingStep = 50.0;

//+------------------------------------------------------------------+
//| EXECUTION SETTINGS                                                |
//+------------------------------------------------------------------+
input group "=== EXECUTION SETTINGS ==="

input int
   InpDeviationPoints = 20;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
int g_rsiHandle = INVALID_HANDLE;

datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Validate RSI period
   if(InpRSIPeriod <= 0)
     {
      Print("ERROR: RSI period must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Validate Buy RSI level
   if(InpBuyRSILevel < 0.0 || InpBuyRSILevel > 100.0)
     {
      Print("ERROR: Buy RSI level must be between 0 and 100.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Validate Sell RSI level
   if(InpSellRSILevel < 0.0 || InpSellRSILevel > 100.0)
     {
      Print("ERROR: Sell RSI level must be between 0 and 100.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Buy level must be below Sell level
   if(InpBuyRSILevel >= InpSellRSILevel)
     {
      Print("ERROR: Buy RSI level must be lower than Sell RSI level.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Validate fixed lot
   if(InpRiskMode == RISK_FIXED_LOT &&
      InpFixedLot <= 0.0)
     {
      Print("ERROR: Fixed lot must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Validate risk percentage
   if(InpRiskMode == RISK_PERCENT_BALANCE &&
      InpRiskPercent <= 0.0)
     {
      Print("ERROR: Risk percent must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Validate Stop Loss
   if(InpUseStopLoss &&
      InpStopLossPoints <= 0.0)
     {
      Print("ERROR: Stop loss points must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Validate Take Profit
   if(InpUseTakeProfit &&
      InpTakeProfitPoints <= 0.0)
     {
      Print("ERROR: Take profit points must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Validate trailing stop
   if(InpUseTrailingStop)
     {
      if(InpTrailingStart <= 0.0)
        {
         Print("ERROR: Trailing start must be greater than zero.");
         return INIT_PARAMETERS_INCORRECT;
        }

      if(InpTrailingDistance <= 0.0)
        {
         Print("ERROR: Trailing distance must be greater than zero.");
         return INIT_PARAMETERS_INCORRECT;
        }

      if(InpTrailingStep < 0.0)
        {
         Print("ERROR: Trailing step cannot be negative.");
         return INIT_PARAMETERS_INCORRECT;
        }
     }

   //--- Create RSI handle
   g_rsiHandle = iRSI(
      _Symbol,
      InpRSITimeframe,
      InpRSIPeriod,
      InpRSIPrice
   );

   if(g_rsiHandle == INVALID_HANDLE)
     {
      Print(
         "ERROR: Failed to create RSI handle. Error = ",
         GetLastError()
      );

      return INIT_FAILED;
     }

   //--- Configure CTrade
   trade.SetExpertMagicNumber(InpMagicNumber);

   trade.SetDeviationInPoints(
      InpDeviationPoints
   );

   trade.SetTypeFillingBySymbol(
      _Symbol
   );

   //--- Initialize current bar
   g_lastBarTime = iTime(
      _Symbol,
      InpRSITimeframe,
      0
   );

   Print("========================================");
   Print("EA12 INITIALIZED");
   Print("Symbol       : ", _Symbol);
   Print("RSI Period   : ", InpRSIPeriod);
   Print("Buy Level    : ", InpBuyRSILevel);
   Print("Sell Level   : ", InpSellRSILevel);
   Print("Magic Number : ", InpMagicNumber);
   Print("========================================");

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_rsiHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_rsiHandle);

      g_rsiHandle = INVALID_HANDLE;
     }

   Print(
      "EA12 stopped. Reason = ",
      reason
   );
  }

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Manage existing positions every tick
   if(InpUseTrailingStop)
      ManageTrailingStop();

   //--- Only evaluate entry on new candle
   if(!IsNewBar())
      return;

   //--- Get RSI values
   double currentRSI = 0.0;
   double previousRSI = 0.0;

   if(!GetRSIValues(
         currentRSI,
         previousRSI))
      return;

   //--- Only one position
   if(InpOnePositionOnly &&
      HasOurPosition())
      return;

   //--- BUY
   if(InpAllowBuy)
     {
      if(IsBuySignal(
            currentRSI,
            previousRSI))
        {
         OpenBuy();
         return;
        }
     }

   //--- SELL
   if(InpAllowSell)
     {
      if(IsSellSignal(
            currentRSI,
            previousRSI))
        {
         OpenSell();
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| New bar detection                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime currentBarTime =
      iTime(
         _Symbol,
         InpRSITimeframe,
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

//+------------------------------------------------------------------+
//| Get RSI values                                                    |
//+------------------------------------------------------------------+
bool GetRSIValues(
   double &currentValue,
   double &previousValue)
  {
   if(g_rsiHandle == INVALID_HANDLE)
      return false;

   //--- Dynamic array
   //--- This avoids the "static allocated array" warning.
   double rsiBuffer[];

   ArraySetAsSeries(
      rsiBuffer,
      true
   );

   //--- Read two closed candles
   //
   //--- Shift 1 = latest closed candle
   //--- Shift 2 = previous closed candle
   //
   int copied = CopyBuffer(
      g_rsiHandle,
      0,
      1,
      2,
      rsiBuffer
   );

   if(copied != 2)
     {
      Print(
         "WARNING: Unable to read RSI data. Error = ",
         GetLastError()
      );

      return false;
     }

   currentValue =
      rsiBuffer[0];

   previousValue =
      rsiBuffer[1];

   return true;
  }

//+------------------------------------------------------------------+
//| BUY signal                                                        |
//+------------------------------------------------------------------+
bool IsBuySignal(
   const double currentRSI,
   const double previousRSI)
  {
   //--- RSI crosses downward into oversold
   //
   // Example:
   // Previous = 35
   // Current  = 28
   // Buy Level = 30
   //
   if(previousRSI > InpBuyRSILevel &&
      currentRSI <= InpBuyRSILevel)
     {
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| SELL signal                                                       |
//+------------------------------------------------------------------+
bool IsSellSignal(
   const double currentRSI,
   const double previousRSI)
  {
   //--- RSI crosses upward into overbought
   //
   // Example:
   // Previous = 65
   // Current  = 72
   // Sell Level = 70
   //
   if(previousRSI < InpSellRSILevel &&
      currentRSI >= InpSellRSILevel)
     {
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Open BUY                                                          |
//+------------------------------------------------------------------+
void OpenBuy()
  {
   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );

   if(ask <= 0.0)
     {
      Print("ERROR: Invalid Ask price.");
      return;
     }

   double sl = 0.0;
   double tp = 0.0;

   //--- Stop Loss
   if(InpUseStopLoss)
     {
      sl =
         ask -
         InpStopLossPoints * _Point;

      sl =
         NormalizePrice(sl);
     }

   //--- Take Profit
   if(InpUseTakeProfit)
     {
      tp =
         ask +
         InpTakeProfitPoints * _Point;

      tp =
         NormalizePrice(tp);
     }

   //--- Respect broker stop level
   AdjustBuyStops(
      ask,
      sl,
      tp
   );

   //--- Calculate lot
   double lot =
      CalculateLotSize(
         ORDER_TYPE_BUY,
         ask,
         sl
      );

   if(lot <= 0.0)
     {
      Print("ERROR: Invalid calculated lot size.");
      return;
     }

   ResetLastError();

   bool result =
      trade.Buy(
         lot,
         _Symbol,
         0.0,
         sl,
         tp,
         InpTradeComment
      );

   if(!result)
     {
      Print(
         "BUY FAILED | Retcode = ",
         trade.ResultRetcode(),
         " | Description = ",
         trade.ResultRetcodeDescription(),
         " | Error = ",
         GetLastError()
      );

      return;
     }

   Print(
      "BUY OPENED | Lot = ",
      DoubleToString(
         lot,
         LotDigits()
      ),
      " | Price = ",
      DoubleToString(
         trade.ResultPrice(),
         _Digits
      ),
      " | SL = ",
      DoubleToString(
         sl,
         _Digits
      ),
      " | TP = ",
      DoubleToString(
         tp,
         _Digits
      )
   );
  }

//+------------------------------------------------------------------+
//| Open SELL                                                         |
//+------------------------------------------------------------------+
void OpenSell()
  {
   double bid =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_BID
      );

   if(bid <= 0.0)
     {
      Print("ERROR: Invalid Bid price.");
      return;
     }

   double sl = 0.0;
   double tp = 0.0;

   //--- Stop Loss
   if(InpUseStopLoss)
     {
      sl =
         bid +
         InpStopLossPoints * _Point;

      sl =
         NormalizePrice(sl);
     }

   //--- Take Profit
   if(InpUseTakeProfit)
     {
      tp =
         bid -
         InpTakeProfitPoints * _Point;

      tp =
         NormalizePrice(tp);
     }

   //--- Respect broker stop level
   AdjustSellStops(
      bid,
      sl,
      tp
   );

   //--- Calculate lot
   double lot =
      CalculateLotSize(
         ORDER_TYPE_SELL,
         bid,
         sl
      );

   if(lot <= 0.0)
     {
      Print("ERROR: Invalid calculated lot size.");
      return;
     }

   ResetLastError();

   bool result =
      trade.Sell(
         lot,
         _Symbol,
         0.0,
         sl,
         tp,
         InpTradeComment
      );

   if(!result)
     {
      Print(
         "SELL FAILED | Retcode = ",
         trade.ResultRetcode(),
         " | Description = ",
         trade.ResultRetcodeDescription(),
         " | Error = ",
         GetLastError()
      );

      return;
     }

   Print(
      "SELL OPENED | Lot = ",
      DoubleToString(
         lot,
         LotDigits()
      ),
      " | Price = ",
      DoubleToString(
         trade.ResultPrice(),
         _Digits
      ),
      " | SL = ",
      DoubleToString(
         sl,
         _Digits
      ),
      " | TP = ",
      DoubleToString(
         tp,
         _Digits
      )
   );
  }

//+------------------------------------------------------------------+
//| Calculate lot size                                                |
//+------------------------------------------------------------------+
double CalculateLotSize(
   const ENUM_ORDER_TYPE orderType,
   const double entryPrice,
   const double stopLoss)
  {
   //--- Fixed lot
   if(InpRiskMode == RISK_FIXED_LOT)
      return NormalizeVolume(
         InpFixedLot
      );

   //--- Percentage risk requires SL
   if(stopLoss <= 0.0)
     {
      Print(
         "WARNING: Percentage risk selected but ",
         "Stop Loss is disabled. Using minimum lot."
      );

      double minVolume =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_VOLUME_MIN
         );

      return NormalizeVolume(
         minVolume
      );
     }

   //--- Account balance
   double balance =
      AccountInfoDouble(
         ACCOUNT_BALANCE
      );

   if(balance <= 0.0)
      return 0.0;

   //--- Money at risk
   double riskMoney =
      balance *
      InpRiskPercent /
      100.0;

   if(riskMoney <= 0.0)
      return 0.0;

   //--- Calculate loss for one lot
   double profit = 0.0;

   bool calculated =
      OrderCalcProfit(
         orderType,
         _Symbol,
         1.0,
         entryPrice,
         stopLoss,
         profit
      );

   if(!calculated)
     {
      Print(
         "ERROR: OrderCalcProfit failed. Error = ",
         GetLastError()
      );

      return 0.0;
     }

   double lossPerLot =
      MathAbs(profit);

   if(lossPerLot <= 0.0)
      return 0.0;

   //--- Calculate volume
   double volume =
      riskMoney /
      lossPerLot;

   return NormalizeVolume(
      volume
   );
  }

//+------------------------------------------------------------------+
//| Normalize volume                                                  |
//+------------------------------------------------------------------+
double NormalizeVolume(
   double volume)
  {
   double minVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   double maxVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );

   double stepVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(minVolume <= 0.0 ||
      maxVolume <= 0.0 ||
      stepVolume <= 0.0)
      return 0.0;

   //--- Maximum
   volume =
      MathMin(
         volume,
         maxVolume
      );

   //--- Minimum
   volume =
      MathMax(
         volume,
         minVolume
      );

   //--- Align to broker volume step
   volume =
      MathFloor(
         volume /
         stepVolume
      ) *
      stepVolume;

   //--- Make sure it is still above minimum
   if(volume < minVolume)
      volume = minVolume;

   return NormalizeDouble(
      volume,
      LotDigits()
   );
  }

//+------------------------------------------------------------------+
//| Lot digits                                                        |
//+------------------------------------------------------------------+
int LotDigits()
  {
   double step =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(step >= 1.0)
      return 0;

   if(step >= 0.1)
      return 1;

   if(step >= 0.01)
      return 2;

   if(step >= 0.001)
      return 3;

   return 4;
  }

//+------------------------------------------------------------------+
//| Normalize price                                                   |
//+------------------------------------------------------------------+
double NormalizePrice(
   const double price)
  {
   return NormalizeDouble(
      price,
      _Digits
   );
  }

//+------------------------------------------------------------------+
//| Check our position                                                |
//+------------------------------------------------------------------+
bool HasOurPosition()
  {
   int total =
      PositionsTotal();

   for(int i = total - 1;
       i >= 0;
       i--)
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

      ulong magic =
         (ulong)PositionGetInteger(
            POSITION_MAGIC
         );

      if(symbol == _Symbol &&
         magic == InpMagicNumber)
        {
         return true;
        }
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Trailing stop                                                     |
//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   int total =
      PositionsTotal();

   for(int i = total - 1;
       i >= 0;
       i--)
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

      ulong magic =
         (ulong)PositionGetInteger(
            POSITION_MAGIC
         );

      //--- Only manage this EA's positions
      if(symbol != _Symbol ||
         magic != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE positionType =
         (ENUM_POSITION_TYPE)
         PositionGetInteger(
            POSITION_TYPE
         );

      double openPrice =
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

      double bid =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_BID
         );

      double ask =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_ASK
         );

      if(bid <= 0.0 ||
         ask <= 0.0)
         continue;

      //==============================================================
      // BUY
      //==============================================================
      if(positionType == POSITION_TYPE_BUY)
        {
         double profitPoints =
            (bid - openPrice) /
            _Point;

         //--- Wait until trailing activation
         if(profitPoints <
            InpTrailingStart)
            continue;

         double newSL =
            bid -
            InpTrailingDistance *
            _Point;

         newSL =
            NormalizePrice(
               newSL
            );

         //--- Broker minimum distance
         double minimumDistance =
            GetMinimumStopDistance();

         double maximumAllowedSL =
            bid -
            minimumDistance;

         if(newSL >
            maximumAllowedSL)
           {
            newSL =
               NormalizePrice(
                  maximumAllowedSL
               );
           }

         //--- Never move SL backwards
         if(currentSL > 0.0 &&
            newSL <= currentSL)
            continue;

         //--- Trailing step
         if(currentSL > 0.0 &&
            (newSL - currentSL) <
            InpTrailingStep *
            _Point)
            continue;

         if(newSL <= 0.0)
            continue;

         ModifyPosition(
            ticket,
            newSL,
            currentTP
         );
        }

      //==============================================================
      // SELL
      //==============================================================
      else if(positionType ==
              POSITION_TYPE_SELL)
        {
         double profitPoints =
            (openPrice - ask) /
            _Point;

         //--- Wait until trailing activation
         if(profitPoints <
            InpTrailingStart)
            continue;

         double newSL =
            ask +
            InpTrailingDistance *
            _Point;

         newSL =
            NormalizePrice(
               newSL
            );

         //--- Broker minimum distance
         double minimumDistance =
            GetMinimumStopDistance();

         double minimumAllowedSL =
            ask +
            minimumDistance;

         if(newSL <
            minimumAllowedSL)
           {
            newSL =
               NormalizePrice(
                  minimumAllowedSL
               );
           }

         //--- Never move SL backwards
         if(currentSL > 0.0 &&
            newSL >= currentSL)
            continue;

         //--- Trailing step
         if(currentSL > 0.0 &&
            (currentSL - newSL) <
            InpTrailingStep *
            _Point)
            continue;

         if(newSL <= 0.0)
            continue;

         ModifyPosition(
            ticket,
            newSL,
            currentTP
         );
        }
     }
  }

//+------------------------------------------------------------------+
//| Modify position                                                   |
//+------------------------------------------------------------------+
bool ModifyPosition(
   const ulong ticket,
   const double newSL,
   const double currentTP)
  {
   ResetLastError();

   bool result =
      trade.PositionModify(
         ticket,
         newSL,
         currentTP
      );

   if(!result)
     {
      Print(
         "TRAILING MODIFY FAILED | Ticket = ",
         ticket,
         " | Retcode = ",
         trade.ResultRetcode(),
         " | Description = ",
         trade.ResultRetcodeDescription(),
         " | Error = ",
         GetLastError()
      );

      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Minimum broker stop distance                                      |
//+------------------------------------------------------------------+
double GetMinimumStopDistance()
  {
   long stopsLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   if(stopsLevel < 0)
      stopsLevel = 0;

   return (double)stopsLevel *
          _Point;
  }

//+------------------------------------------------------------------+
//| Adjust BUY stops                                                  |
//+------------------------------------------------------------------+
void AdjustBuyStops(
   const double entryPrice,
   double &sl,
   double &tp)
  {
   double minimumDistance =
      GetMinimumStopDistance();

   //--- BUY SL must be below price
   if(sl > 0.0)
     {
      double maximumSL =
         entryPrice -
         minimumDistance;

      if(sl > maximumSL)
        {
         sl =
            NormalizePrice(
               maximumSL
            );
        }
     }

   //--- BUY TP must be above price
   if(tp > 0.0)
     {
      double minimumTP =
         entryPrice +
         minimumDistance;

      if(tp < minimumTP)
        {
         tp =
            NormalizePrice(
               minimumTP
            );
        }
     }
  }

//+------------------------------------------------------------------+
//| Adjust SELL stops                                                 |
//+------------------------------------------------------------------+
void AdjustSellStops(
   const double entryPrice,
   double &sl,
   double &tp)
  {
   double minimumDistance =
      GetMinimumStopDistance();

   //--- SELL SL must be above price
   if(sl > 0.0)
     {
      double minimumSL =
         entryPrice +
         minimumDistance;

      if(sl < minimumSL)
        {
         sl =
            NormalizePrice(
               minimumSL
            );
        }
     }

   //--- SELL TP must be below price
   if(tp > 0.0)
     {
      double maximumTP =
         entryPrice -
         minimumDistance;

      if(tp > maximumTP)
        {
         tp =
            NormalizePrice(
               maximumTP
            );
        }
     }
  }

//+------------------------------------------------------------------+
//| END OF EA12                                                       |
//+------------------------------------------------------------------+