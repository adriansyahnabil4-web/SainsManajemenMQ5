//+------------------------------------------------------------------+
//|                                                     EA15.mq5     |
//|                 Time Based Breakout / Pending Order EA           |
//|                         Pure MQL5 - MT5                          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Time-based Buy Stop/Sell Stop EA with Percent/ATR distances"
#property description "Money/Percent risk management, Break-Even and Trailing Stop"
#property description "Pure MQL5 - MT5 only"

//--- Trading
#include <Trade/Trade.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//| ENUMS                                                            |
//+------------------------------------------------------------------+
enum ENUM_DISTANCE_MODE
  {
   DISTANCE_PERCENT = 0,
   DISTANCE_ATR     = 1
  };

enum ENUM_RISK_MODE
  {
   RISK_MONEY   = 0,
   RISK_BALANCE = 1
  };

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+

//--- General
input group "=== GENERAL ==="

input ulong InpMagicNumber = 15001;       // Magic Number

input bool  InpAllowBuy  = true;          // Allow Buy Stop
input bool  InpAllowSell = true;          // Allow Sell Stop

//--- Time
input group "=== DAILY TIME SETTINGS ==="

input string InpSetupTime   = "06:00";     // Setup Time
input string InpCleanupTime = "22:00";     // Cleanup Time

input bool InpClosePositionsAtCleanup = false; // Close positions at cleanup

//--- Distance calculation
input group "=== DISTANCE CALCULATION ==="

input ENUM_DISTANCE_MODE InpDistanceMode = DISTANCE_PERCENT;
// DISTANCE_PERCENT = Percentage of price
// DISTANCE_ATR     = ATR based

//--- Percent settings
input double InpEntryPercent = 0.10;       // Entry Distance (%)
input double InpSLPercent    = 0.10;       // Stop Loss Distance (%)
input double InpTPPercent    = 0.20;       // Take Profit Distance (%)

//--- ATR settings
input group "=== ATR SETTINGS ==="

input ENUM_TIMEFRAMES InpATRTimeframe = PERIOD_M15; // ATR Timeframe
input int    InpATRPeriod = 14;                     // ATR Period

input double InpEntryATRMultiplier = 1.0;           // Entry ATR Multiplier
input double InpSLATRMultiplier    = 1.0;           // SL ATR Multiplier
input double InpTPATRMultiplier    = 2.0;           // TP ATR Multiplier

//--- Risk
input group "=== RISK MANAGEMENT ==="

input ENUM_RISK_MODE InpRiskMode = RISK_MONEY;

input double InpRiskMoney = 100.0;       // Risk per trade in account currency
input double InpRiskPercent = 1.0;       // Risk per trade (% balance)

input double InpMinLot = 0.0;            // Minimum lot override (0 = broker minimum)
input double InpMaxLot = 0.0;            // Maximum lot override (0 = broker maximum)

//--- Break Even
input group "=== BREAK EVEN ==="

input bool   InpUseBreakEven = true;      // Enable Break Even

input double InpBreakEvenTriggerPercent = 0.10; // BE trigger (%)
input double InpBreakEvenOffsetPercent  = 0.00; // BE offset (%)

input double InpBreakEvenTriggerATR = 1.0; // BE trigger ATR multiplier
input double InpBreakEvenOffsetATR  = 0.0; // BE offset ATR multiplier

//--- Trailing Stop
input group "=== TRAILING STOP ==="

input bool InpUseTrailing = true;          // Enable Trailing Stop

input double InpTrailingTriggerPercent = 0.20; // Trailing trigger (%)
input double InpTrailingDistancePercent = 0.10; // Trailing distance (%)
input double InpTrailingStepPercent    = 0.05; // Trailing step (%)

input double InpTrailingTriggerATR = 1.0; // Trailing trigger ATR
input double InpTrailingDistanceATR = 1.0; // Trailing distance ATR
input double InpTrailingStepATR     = 0.25; // Trailing step ATR

//--- Execution
input group "=== EXECUTION ==="

input int InpDeviationPoints = 20;         // Maximum deviation
input bool InpDeleteOppositeAfterFill = false;
// If true, when one pending order becomes a position,
// the opposite pending order is deleted.

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+

int g_atrHandle = INVALID_HANDLE;

int g_setupHour   = 6;
int g_setupMinute = 0;

int g_cleanupHour   = 22;
int g_cleanupMinute = 0;

string g_globalPrefix = "EA15_";

//+------------------------------------------------------------------+
//| HELPER: Normalize price                                           |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
  {
   return NormalizeDouble(price,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
  }

//+------------------------------------------------------------------+
//| HELPER: Normalize volume                                          |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
   double brokerMin  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double brokerMax  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double volumeStep = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   double minLot = brokerMin;
   double maxLot = brokerMax;

   if(InpMinLot > 0.0)
      minLot = MathMax(minLot,InpMinLot);

   if(InpMaxLot > 0.0)
      maxLot = MathMin(maxLot,InpMaxLot);

   if(maxLot < minLot)
      maxLot = minLot;

   volume = MathMax(volume,minLot);
   volume = MathMin(volume,maxLot);

   if(volumeStep > 0.0)
      volume = MathFloor(volume/volumeStep)*volumeStep;

   volume = MathMax(volume,minLot);
   volume = MathMin(volume,maxLot);

   return NormalizeDouble(volume,8);
  }

//+------------------------------------------------------------------+
//| HELPER: Parse HH:MM                                               |
//+------------------------------------------------------------------+
bool ParseTimeString(const string value,int &hour,int &minute)
  {
   string parts[];
   int count = StringSplit(value,':',parts);

   if(count != 2)
      return false;

   hour   = (int)StringToInteger(parts[0]);
   minute = (int)StringToInteger(parts[1]);

   if(hour < 0 || hour > 23)
      return false;

   if(minute < 0 || minute > 59)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| HELPER: Day key                                                   |
//+------------------------------------------------------------------+
int GetDayKey(const datetime timeValue)
  {
   MqlDateTime dt;
   TimeToStruct(timeValue,dt);

   return dt.year*10000 + dt.mon*100 + dt.day;
  }

//+------------------------------------------------------------------+
//| HELPER: Global variable name                                      |
//+------------------------------------------------------------------+
string GetSetupGlobalName()
  {
   return g_globalPrefix +
          IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) +
          "_" +
          _Symbol +
          "_" +
          IntegerToString((long)InpMagicNumber) +
          "_SETUP";
  }

//+------------------------------------------------------------------+
//| Check if setup already executed today                             |
//+------------------------------------------------------------------+
bool SetupAlreadyDoneToday(const datetime now)
  {
   string name = GetSetupGlobalName();

   if(!GlobalVariableCheck(name))
      return false;

   double storedDay = GlobalVariableGet(name);

   return ((int)storedDay == GetDayKey(now));
  }

//+------------------------------------------------------------------+
//| Mark setup as completed                                           |
//+------------------------------------------------------------------+
void MarkSetupDone(const datetime now)
  {
   string name = GetSetupGlobalName();

   GlobalVariableSet(name,(double)GetDayKey(now));
  }

//+------------------------------------------------------------------+
//| Get minutes since midnight                                        |
//+------------------------------------------------------------------+
int GetMinutesOfDay(const datetime timeValue)
  {
   MqlDateTime dt;
   TimeToStruct(timeValue,dt);

   return dt.hour*60 + dt.min;
  }

//+------------------------------------------------------------------+
//| Check if cleanup time has passed                                  |
//+------------------------------------------------------------------+
bool CleanupTimeReached(const datetime now)
  {
   int currentMinutes = GetMinutesOfDay(now);
   int cleanupMinutes = g_cleanupHour*60 + g_cleanupMinute;

   return (currentMinutes >= cleanupMinutes);
  }

//+------------------------------------------------------------------+
//| Get ATR                                                            |
//+------------------------------------------------------------------+
double GetATR()
  {
   if(g_atrHandle == INVALID_HANDLE)
      return 0.0;

   double buffer[1];

   int copied = CopyBuffer(g_atrHandle,0,0,1,buffer);

   if(copied != 1)
      return 0.0;

   if(buffer[0] <= 0.0)
      return 0.0;

   return buffer[0];
  }

//+------------------------------------------------------------------+
//| Get distance                                                      |
//+------------------------------------------------------------------+
double GetDistance(const double percentValue,
                   const double atrMultiplier,
                   const double referencePrice)
  {
   if(InpDistanceMode == DISTANCE_PERCENT)
     {
      if(percentValue <= 0.0)
         return 0.0;

      return referencePrice * percentValue / 100.0;
     }

   double atr = GetATR();

   if(atr <= 0.0 || atrMultiplier <= 0.0)
      return 0.0;

   return atr * atrMultiplier;
  }

//+------------------------------------------------------------------+
//| Get entry distance                                                |
//+------------------------------------------------------------------+
double GetEntryDistance(const double referencePrice)
  {
   return GetDistance(InpEntryPercent,
                      InpEntryATRMultiplier,
                      referencePrice);
  }

//+------------------------------------------------------------------+
//| Get SL distance                                                   |
//+------------------------------------------------------------------+
double GetSLDistance(const double referencePrice)
  {
   return GetDistance(InpSLPercent,
                      InpSLATRMultiplier,
                      referencePrice);
  }

//+------------------------------------------------------------------+
//| Get TP distance                                                   |
//+------------------------------------------------------------------+
double GetTPDistance(const double referencePrice)
  {
   return GetDistance(InpTPPercent,
                      InpTPATRMultiplier,
                      referencePrice);
  }

//+------------------------------------------------------------------+
//| Calculate money risk                                              |
//+------------------------------------------------------------------+
double GetRiskMoney()
  {
   if(InpRiskMode == RISK_MONEY)
      return InpRiskMoney;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   return balance * InpRiskPercent / 100.0;
  }

//+------------------------------------------------------------------+
//| Calculate lot based on SL distance                                |
//+------------------------------------------------------------------+
double CalculateLotSize(const double entryPrice,
                        const double stopLossPrice)
  {
   double riskMoney = GetRiskMoney();

   if(riskMoney <= 0.0)
      return 0.0;

   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);

   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;

   double priceDistance = MathAbs(entryPrice-stopLossPrice);

   if(priceDistance <= 0.0)
      return 0.0;

   // Money loss for 1 lot at the specified SL distance.
   double lossPerLot = (priceDistance/tickSize)*tickValue;

   if(lossPerLot <= 0.0)
      return 0.0;

   double volume = riskMoney/lossPerLot;

   return NormalizeVolume(volume);
  }

//+------------------------------------------------------------------+
//| Check trading permission                                         |
//+------------------------------------------------------------------+
bool TradingAllowed()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   long tradeMode = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);

   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Check if pending order belongs to this EA                         |
//+------------------------------------------------------------------+
bool IsOurPendingOrder(const ulong ticket)
  {
   if(ticket == 0)
      return false;

   if(!OrderSelect(ticket))
      return false;

   string symbol = OrderGetString(ORDER_SYMBOL);

   if(symbol != _Symbol)
      return false;

   ulong magic = (ulong)OrderGetInteger(ORDER_MAGIC);

   if(magic != InpMagicNumber)
      return false;

   ENUM_ORDER_TYPE type =
      (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

   if(type != ORDER_TYPE_BUY_STOP &&
      type != ORDER_TYPE_SELL_STOP)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Check if position belongs to this EA                              |
//+------------------------------------------------------------------+
bool IsOurPosition(const ulong ticket)
  {
   if(ticket == 0)
      return false;

   if(!PositionSelectByTicket(ticket))
      return false;

   string symbol = PositionGetString(POSITION_SYMBOL);

   if(symbol != _Symbol)
      return false;

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

   if(magic != InpMagicNumber)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Delete our pending orders                                         |
//+------------------------------------------------------------------+
void DeleteOurPendingOrders()
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!IsOurPendingOrder(ticket))
         continue;

      ResetLastError();

      if(!trade.OrderDelete(ticket))
        {
         Print("EA15: Failed to delete pending order #",
               ticket,
               ". Retcode=",
               trade.ResultRetcode(),
               " ",
               trade.ResultRetcodeDescription());
        }
      else
        {
         Print("EA15: Pending order #",ticket," deleted.");
        }
     }
  }

//+------------------------------------------------------------------+
//| Close our positions                                               |
//+------------------------------------------------------------------+
void CloseOurPositions()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!IsOurPosition(ticket))
         continue;

      ResetLastError();

      if(!trade.PositionClose(ticket))
        {
         Print("EA15: Failed to close position #",
               ticket,
               ". Retcode=",
               trade.ResultRetcode(),
               " ",
               trade.ResultRetcodeDescription());
        }
      else
        {
         Print("EA15: Position #",ticket," closed at cleanup.");
        }
     }
  }

//+------------------------------------------------------------------+
//| Delete opposite pending orders                                    |
//+------------------------------------------------------------------+
void DeleteOppositePendingOrders(const ENUM_POSITION_TYPE positionType)
  {
   ENUM_ORDER_TYPE oppositeType;

   if(positionType == POSITION_TYPE_BUY)
      oppositeType = ORDER_TYPE_SELL_STOP;
   else
      oppositeType = ORDER_TYPE_BUY_STOP;

   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!IsOurPendingOrder(ticket))
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != oppositeType)
         continue;

      if(!trade.OrderDelete(ticket))
        {
         Print("EA15: Failed deleting opposite order #",
               ticket,
               ". Retcode=",
               trade.ResultRetcode(),
               " ",
               trade.ResultRetcodeDescription());
        }
      else
        {
         Print("EA15: Opposite pending order #",
               ticket,
               " deleted.");
        }
     }
  }

//+------------------------------------------------------------------+
//| Place Buy Stop                                                    |
//+------------------------------------------------------------------+
bool PlaceBuyStop(const double ask)
  {
   double entryDistance = GetEntryDistance(ask);
   double slDistance    = GetSLDistance(ask);
   double tpDistance    = GetTPDistance(ask);

   if(entryDistance <= 0.0 ||
      slDistance <= 0.0 ||
      tpDistance <= 0.0)
     {
      Print("EA15: Invalid Buy Stop distances.");
      return false;
     }

   double entry = ask + entryDistance;

   double sl = entry - slDistance;
   double tp = entry + tpDistance;

   entry = NormalizePrice(entry);
   sl    = NormalizePrice(sl);
   tp    = NormalizePrice(tp);

   //--- Check broker minimum stop distance
   long stopsLevel =
      SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

   double minimumDistance =
      (double)stopsLevel * _Point;

   if(entry-ask < minimumDistance)
      entry = NormalizePrice(ask+minimumDistance);

   if(entry-sl < minimumDistance)
      sl = NormalizePrice(entry-minimumDistance);

   if(tp-entry < minimumDistance)
      tp = NormalizePrice(entry+minimumDistance);

   double volume = CalculateLotSize(entry,sl);

   if(volume <= 0.0)
     {
      Print("EA15: Invalid calculated Buy Stop volume.");
      return false;
     }

   ResetLastError();

   bool result =
      trade.BuyStop(
         volume,
         entry,
         _Symbol,
         sl,
         tp,
         ORDER_TIME_GTC,
         0,
         "EA15 Buy Stop"
      );

   if(!result)
     {
      Print("EA15: Buy Stop failed. Retcode=",
            trade.ResultRetcode(),
            " ",
            trade.ResultRetcodeDescription());

      return false;
     }

   Print("EA15: Buy Stop placed. Ticket=",
         trade.ResultOrder(),
         " Volume=",
         DoubleToString(volume,2),
         " Entry=",
         DoubleToString(entry,_Digits),
         " SL=",
         DoubleToString(sl,_Digits),
         " TP=",
         DoubleToString(tp,_Digits));

   return true;
  }

//+------------------------------------------------------------------+
//| Place Sell Stop                                                   |
//+------------------------------------------------------------------+
bool PlaceSellStop(const double bid)
  {
   double entryDistance = GetEntryDistance(bid);
   double slDistance    = GetSLDistance(bid);
   double tpDistance    = GetTPDistance(bid);

   if(entryDistance <= 0.0 ||
      slDistance <= 0.0 ||
      tpDistance <= 0.0)
     {
      Print("EA15: Invalid Sell Stop distances.");
      return false;
     }

   double entry = bid - entryDistance;

   double sl = entry + slDistance;
   double tp = entry - tpDistance;

   entry = NormalizePrice(entry);
   sl    = NormalizePrice(sl);
   tp    = NormalizePrice(tp);

   //--- Check broker minimum stop distance
   long stopsLevel =
      SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

   double minimumDistance =
      (double)stopsLevel * _Point;

   if(bid-entry < minimumDistance)
      entry = NormalizePrice(bid-minimumDistance);

   if(sl-entry < minimumDistance)
      sl = NormalizePrice(entry+minimumDistance);

   if(entry-tp < minimumDistance)
      tp = NormalizePrice(entry-minimumDistance);

   double volume = CalculateLotSize(entry,sl);

   if(volume <= 0.0)
     {
      Print("EA15: Invalid calculated Sell Stop volume.");
      return false;
     }

   ResetLastError();

   bool result =
      trade.SellStop(
         volume,
         entry,
         _Symbol,
         sl,
         tp,
         ORDER_TIME_GTC,
         0,
         "EA15 Sell Stop"
      );

   if(!result)
     {
      Print("EA15: Sell Stop failed. Retcode=",
            trade.ResultRetcode(),
            " ",
            trade.ResultRetcodeDescription());

      return false;
     }

   Print("EA15: Sell Stop placed. Ticket=",
         trade.ResultOrder(),
         " Volume=",
         DoubleToString(volume,2),
         " Entry=",
         DoubleToString(entry,_Digits),
         " SL=",
         DoubleToString(sl,_Digits),
         " TP=",
         DoubleToString(tp,_Digits));

   return true;
  }

//+------------------------------------------------------------------+
//| Setup daily pending orders                                        |
//+------------------------------------------------------------------+
void ExecuteDailySetup(const datetime now)
  {
   if(SetupAlreadyDoneToday(now))
      return;

   if(!TradingAllowed())
      return;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol,tick))
      return;

   double ask = tick.ask;
   double bid = tick.bid;

   if(ask <= 0.0 || bid <= 0.0)
      return;

   bool buySuccess  = false;
   bool sellSuccess = false;

   if(InpAllowBuy)
      buySuccess = PlaceBuyStop(ask);

   if(InpAllowSell)
      sellSuccess = PlaceSellStop(bid);

   // Mark setup as done if at least one requested order was placed.
   if((!InpAllowBuy || buySuccess) &&
      (!InpAllowSell || sellSuccess))
     {
      MarkSetupDone(now);

      Print("EA15: Daily setup completed for ",
            TimeToString(now,TIME_DATE));
     }
  }

//+------------------------------------------------------------------+
//| Get BE trigger distance                                           |
//+------------------------------------------------------------------+
double GetBreakEvenTrigger(const double referencePrice)
  {
   return GetDistance(InpBreakEvenTriggerPercent,
                      InpBreakEvenTriggerATR,
                      referencePrice);
  }

//+------------------------------------------------------------------+
//| Get BE offset distance                                             |
//+------------------------------------------------------------------+
double GetBreakEvenOffset(const double referencePrice)
  {
   return GetDistance(InpBreakEvenOffsetPercent,
                      InpBreakEvenOffsetATR,
                      referencePrice);
  }

//+------------------------------------------------------------------+
//| Get trailing trigger                                              |
//+------------------------------------------------------------------+
double GetTrailingTrigger(const double referencePrice)
  {
   return GetDistance(InpTrailingTriggerPercent,
                      InpTrailingTriggerATR,
                      referencePrice);
  }

//+------------------------------------------------------------------+
//| Get trailing distance                                             |
//+------------------------------------------------------------------+
double GetTrailingDistance(const double referencePrice)
  {
   return GetDistance(InpTrailingDistancePercent,
                      InpTrailingDistanceATR,
                      referencePrice);
  }

//+------------------------------------------------------------------+
//| Get trailing step                                                 |
//+------------------------------------------------------------------+
double GetTrailingStep(const double referencePrice)
  {
   return GetDistance(InpTrailingStepPercent,
                      InpTrailingStepATR,
                      referencePrice);
  }

//+------------------------------------------------------------------+
//| Modify position SL                                                |
//+------------------------------------------------------------------+
bool ModifyPositionSL(const ulong ticket,
                      const double newSL,
                      const double currentTP)
  {
   double normalizedSL = NormalizePrice(newSL);

   if(!trade.PositionModify(ticket,normalizedSL,currentTP))
     {
      Print("EA15: PositionModify failed for #",
            ticket,
            ". Retcode=",
            trade.ResultRetcode(),
            " ",
            trade.ResultRetcodeDescription());

      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Manage Buy position                                               |
//+------------------------------------------------------------------+
void ManageBuyPosition(const ulong ticket,
                       const double bid,
                       const double openPrice,
                       const double currentSL,
                       const double currentTP)
  {
   double profitDistance = bid-openPrice;

   if(profitDistance <= 0.0)
      return;

   //--- Break Even
   if(InpUseBreakEven)
     {
      double trigger = GetBreakEvenTrigger(openPrice);
      double offset  = GetBreakEvenOffset(openPrice);

      if(trigger > 0.0 && profitDistance >= trigger)
        {
         double beSL = openPrice + offset;

         long stopsLevel =
            SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

         double minimumDistance =
            (double)stopsLevel*_Point;

         if(bid-beSL >= minimumDistance)
           {
            bool shouldMove = false;

            if(currentSL <= 0.0)
               shouldMove = true;
            else if(beSL > currentSL + (_Point*0.5))
               shouldMove = true;

            if(shouldMove)
               ModifyPositionSL(ticket,beSL,currentTP);
           }
        }
     }

   //--- Traditional trailing
   if(InpUseTrailing)
     {
      double trigger  = GetTrailingTrigger(openPrice);
      double distance = GetTrailingDistance(openPrice);
      double step     = GetTrailingStep(openPrice);

      if(trigger <= 0.0 || distance <= 0.0)
         return;

      if(profitDistance < trigger)
         return;

      double newSL = bid-distance;

      long stopsLevel =
         SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

      double minimumDistance =
         (double)stopsLevel*_Point;

      if(bid-newSL < minimumDistance)
         newSL = bid-minimumDistance;

      newSL = NormalizePrice(newSL);

      bool shouldMove = false;

      if(currentSL <= 0.0)
         shouldMove = true;
      else
        {
         if(step <= 0.0)
            shouldMove = (newSL > currentSL+(_Point*0.5));
         else
            shouldMove = (newSL-currentSL >= step);
        }

      if(shouldMove)
        {
         // Never move SL backward.
         if(currentSL <= 0.0 || newSL > currentSL+(_Point*0.5))
            ModifyPositionSL(ticket,newSL,currentTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Manage Sell position                                              |
//+------------------------------------------------------------------+
void ManageSellPosition(const ulong ticket,
                        const double ask,
                        const double openPrice,
                        const double currentSL,
                        const double currentTP)
  {
   double profitDistance = openPrice-ask;

   if(profitDistance <= 0.0)
      return;

   //--- Break Even
   if(InpUseBreakEven)
     {
      double trigger = GetBreakEvenTrigger(openPrice);
      double offset  = GetBreakEvenOffset(openPrice);

      if(trigger > 0.0 && profitDistance >= trigger)
        {
         double beSL = openPrice-offset;

         long stopsLevel =
            SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

         double minimumDistance =
            (double)stopsLevel*_Point;

         if(beSL-ask >= minimumDistance)
           {
            bool shouldMove = false;

            if(currentSL <= 0.0)
               shouldMove = true;
            else if(beSL < currentSL-(_Point*0.5))
               shouldMove = true;

            if(shouldMove)
               ModifyPositionSL(ticket,beSL,currentTP);
           }
        }
     }

   //--- Traditional trailing
   if(InpUseTrailing)
     {
      double trigger  = GetTrailingTrigger(openPrice);
      double distance = GetTrailingDistance(openPrice);
      double step     = GetTrailingStep(openPrice);

      if(trigger <= 0.0 || distance <= 0.0)
         return;

      if(profitDistance < trigger)
         return;

      double newSL = ask+distance;

      long stopsLevel =
         SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

      double minimumDistance =
         (double)stopsLevel*_Point;

      if(newSL-ask < minimumDistance)
         newSL = ask+minimumDistance;

      newSL = NormalizePrice(newSL);

      bool shouldMove = false;

      if(currentSL <= 0.0)
         shouldMove = true;
      else
        {
         if(step <= 0.0)
            shouldMove = (newSL < currentSL-(_Point*0.5));
         else
            shouldMove = (currentSL-newSL >= step);
        }

      if(shouldMove)
        {
         // Never move SL backward.
         if(currentSL <= 0.0 || newSL < currentSL-(_Point*0.5))
            ModifyPositionSL(ticket,newSL,currentTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Manage all positions                                              |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol,tick))
      return;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!IsOurPosition(ticket))
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double openPrice =
         PositionGetDouble(POSITION_PRICE_OPEN);

      double currentSL =
         PositionGetDouble(POSITION_SL);

      double currentTP =
         PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
        {
         ManageBuyPosition(ticket,
                           tick.bid,
                           openPrice,
                           currentSL,
                           currentTP);
        }
      else if(type == POSITION_TYPE_SELL)
        {
         ManageSellPosition(ticket,
                            tick.ask,
                            openPrice,
                            currentSL,
                            currentTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Initialization                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Parse setup time
   if(!ParseTimeString(InpSetupTime,
                       g_setupHour,
                       g_setupMinute))
     {
      Print("EA15: Invalid Setup Time. Use HH:MM.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Parse cleanup time
   if(!ParseTimeString(InpCleanupTime,
                       g_cleanupHour,
                       g_cleanupMinute))
     {
      Print("EA15: Invalid Cleanup Time. Use HH:MM.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Validate magic
   if(InpMagicNumber == 0)
     {
      Print("EA15: Magic number must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Validate ATR period
   if(InpATRPeriod <= 0)
     {
      Print("EA15: ATR period must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Validate risk
   if(InpRiskMode == RISK_MONEY && InpRiskMoney <= 0.0)
     {
      Print("EA15: Risk money must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpRiskMode == RISK_BALANCE && InpRiskPercent <= 0.0)
     {
      Print("EA15: Risk percentage must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Create ATR handle
   g_atrHandle =
      iATR(_Symbol,InpATRTimeframe,InpATRPeriod);

   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("EA15: Failed to create ATR handle. Error=",
            GetLastError());

      return INIT_FAILED;
     }

   //--- Configure trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   Print("==================================================");
   Print("EA15 initialized");
   Print("Symbol: ",_Symbol);
   Print("Magic: ",InpMagicNumber);
   Print("Setup Time: ",InpSetupTime);
   Print("Cleanup Time: ",InpCleanupTime);
   Print("Distance Mode: ",
         (InpDistanceMode == DISTANCE_PERCENT ?
          "PERCENT" : "ATR"));
   Print("Risk Mode: ",
         (InpRiskMode == RISK_MONEY ?
          "MONEY" : "BALANCE %"));
   Print("==================================================");

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinitialization                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();

   int currentMinutes = GetMinutesOfDay(now);
   int setupMinutes =
      g_setupHour*60 + g_setupMinute;

   int cleanupMinutes =
      g_cleanupHour*60 + g_cleanupMinute;

   //===============================================================
   // CLEANUP
   //===============================================================
   if(currentMinutes >= cleanupMinutes)
     {
      DeleteOurPendingOrders();

      if(InpClosePositionsAtCleanup)
         CloseOurPositions();

      // Do not perform setup after cleanup.
      ManagePositions();

      return;
     }

   //===============================================================
   // DAILY SETUP
   //===============================================================
   if(currentMinutes >= setupMinutes)
     {
      ExecuteDailySetup(now);
     }

   //===============================================================
   // POSITION MANAGEMENT
   //===============================================================
   ManagePositions();

   //===============================================================
   // OPTIONAL: DELETE OPPOSITE ORDER AFTER FILL
   //===============================================================
   if(InpDeleteOppositeAfterFill)
     {
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong ticket = PositionGetTicket(i);

         if(ticket == 0)
            continue;

         if(!IsOurPosition(ticket))
            continue;

         ENUM_POSITION_TYPE type =
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         DeleteOppositePendingOrders(type);
        }
     }
  }

//+------------------------------------------------------------------+
//| Trade transaction                                                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   // This function intentionally remains lightweight.
   // Position/order management is handled from OnTick().
  }

//+------------------------------------------------------------------+