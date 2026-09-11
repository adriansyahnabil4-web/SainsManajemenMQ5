//+------------------------------------------------------------------+
//|                                           RangeBreakout_EA.mq5   |
//|                                  Copyright 2026, MetaTrader 5    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "MT5 Daily Range Breakout Expert Advisor"

#include <Trade\Trade.mqh>

//--- Enums
enum ENUM_TRADE_MODE
{
   TRADE_BOTH = 0,    // Allow both Buy & Sell trades per day
   TRADE_ONE_ONLY = 1 // Allow only 1 trade per day (Cancel second on trigger)
};

//--- Input Parameters
input group "--- Time Settings ---"
input int               InpStartHour    = 8;           // Range Start Hour (0-23)
input int               InpStartMinute  = 0;           // Range Start Minute (0-59)
input int               InpEndHour      = 10;          // Range End Hour (0-23)
input int               InpEndMinute    = 0;           // Range End Minute (0-59)
input int               InpCloseHour    = 18;          // Close/Delete Hour (0-23)
input int               InpCloseMinute  = 0;           // Close/Delete Minute (0-59)

input group "--- Execution Settings ---"
input ENUM_TRADE_MODE   InpTradeMode    = TRADE_ONE_ONLY; // Trade Mode

input group "--- Risk & Money Management ---"
input double            InpRiskAmount   = 100.0;       // Fixed Risk Amount ($)
input double            InpSLFactor     = 1.0;         // Stop Loss Factor (SL = Range * Factor)
input bool              InpUseTP        = true;        // Use Take Profit
input double            InpTPFactor     = 1.5;         // Take Profit Factor (TP = Range * Factor)

input group "--- EA Settings ---"
input ulong             InpMagicNumber  = 888123;      // EA Magic Number
input ulong             InpSlippage     = 10;          // Slippage (Points)
input bool              InpShowVisuals  = true;        // Draw Range Box on Chart

//--- Global Variables
CTrade      trade;
datetime    g_lastDay = 0;
bool        g_rangeProcessed = false;
bool        g_dayClosed = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Configure trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   // Validate inputs
   if(InpStartHour < 0 || InpStartHour > 23 || InpEndHour < 0 || InpEndHour > 23 || InpCloseHour < 0 || InpCloseHour > 23)
   {
      Print("Error: Hour settings must be between 0 and 23.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up visual objects on unload if desired
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   // Calculate today's midnight timestamp
   datetime todayDate = now - (dt.hour * 3600 + dt.min * 60 + dt.sec);

   // Reset daily flags on a new day
   if(todayDate != g_lastDay)
   {
      g_lastDay = todayDate;
      g_rangeProcessed = false;
      g_dayClosed = false;
   }

   // Construct operational timestamps for today
   datetime startTime = GetTimeToday(InpStartHour, InpStartMinute);
   datetime endTime   = GetTimeToday(InpEndHour, InpEndMinute);
   datetime closeTime = GetTimeToday(InpCloseHour, InpCloseMinute);

   // 1. Check Close/Delete Time
   if(now >= closeTime)
   {
      if(!g_dayClosed)
      {
         DeleteAllPendingOrders();
         CloseAllPositions();
         g_dayClosed = true;
         Print("Close time reached. Pending orders deleted and open positions closed.");
      }
      return; // Do not process or trade after close time
   }

   if(g_dayClosed) return;

   // 2. Check if single-trade mode is active and an order has executed
   if(InpTradeMode == TRADE_ONE_ONLY && g_rangeProcessed)
   {
      if(GetOpenPositionCount() > 0 && GetPendingOrderCount() > 0)
      {
         DeleteAllPendingOrders();
         Print("One trade executed. Deleting remaining opposite pending order.");
      }
   }

   // 3. Range formation and order placement logic
   if(now >= endTime && !g_rangeProcessed)
   {
      // Retrieve high and low during the range period using M1 rates for precision
      MqlRates rates[];
      int copied = CopyRates(_Symbol, PERIOD_M1, startTime, endTime, rates);

      if(copied <= 0)
      {
         Print("Waiting for price history data...");
         return;
      }

      double highestPrice = rates[0].high;
      double lowestPrice  = rates[0].low;

      for(int i = 1; i < copied; i++)
      {
         if(rates[i].high > highestPrice) highestPrice = rates[i].high;
         if(rates[i].low < lowestPrice)   lowestPrice  = rates[i].low;
      }

      // Draw Range Box on Chart
      DrawRangeBox(startTime, highestPrice, endTime, lowestPrice);

      double rangeSize = highestPrice - lowestPrice;
      if(rangeSize <= 0)
      {
         Print("Invalid range size calculated.");
         return;
      }

      double slDistance = rangeSize * InpSLFactor;
      double lotSize = CalculateLotSize(slDistance);

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      // Buy Levels
      double buySL = NormalizeDouble(highestPrice - slDistance, digits);
      double buyTP = InpUseTP ? NormalizeDouble(highestPrice + (rangeSize * InpTPFactor), digits) : 0.0;

      // Sell Levels
      double sellSL = NormalizeDouble(lowestPrice + slDistance, digits);
      double sellTP = InpUseTP ? NormalizeDouble(lowestPrice - (rangeSize * InpTPFactor), digits) : 0.0;

      // Execute Buy Order (Market Fallback if Price already broke out)
      if(ask >= highestPrice)
      {
         double marketBuySL = NormalizeDouble(ask - slDistance, digits);
         double marketBuyTP = InpUseTP ? NormalizeDouble(ask + (rangeSize * InpTPFactor), digits) : 0.0;
         trade.Buy(lotSize, _Symbol, ask, marketBuySL, marketBuyTP, "Range Breakout Buy");
      }
      else
      {
         trade.BuyStop(lotSize, NormalizeDouble(highestPrice, digits), _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "Range BuyStop");
      }

      // Execute Sell Order (Market Fallback if Price already broke out)
      if(bid <= lowestPrice)
      {
         double marketSellSL = NormalizeDouble(bid + slDistance, digits);
         double marketSellTP = InpUseTP ? NormalizeDouble(bid - (rangeSize * InpTPFactor), digits) : 0.0;
         trade.Sell(lotSize, _Symbol, bid, marketSellSL, marketSellTP, "Range Breakout Sell");
      }
      else
      {
         trade.SellStop(lotSize, NormalizeDouble(lowestPrice, digits), _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "Range SellStop");
      }

      g_rangeProcessed = true;
   }
}

//+------------------------------------------------------------------+
//| Helper: Get datetime for specific hour & minute today            |
//+------------------------------------------------------------------+
datetime GetTimeToday(int hour, int minute)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = hour;
   dt.min  = minute;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Helper: Calculate Lot Size based on fixed cash risk              |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(slDistance <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickSize <= 0 || tickValue <= 0 || point <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double pointsCount = slDistance / point;
   double riskPerLot  = pointsCount * (tickValue / (tickSize / point));

   if(riskPerLot <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lot = InpRiskAmount / riskPerLot;

   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / lotStep) * lotStep;

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Helper: Draw visual range rectangle                              |
//+------------------------------------------------------------------+
void DrawRangeBox(datetime t1, double p1, datetime t2, double p2)
{
   if(!InpShowVisuals) return;

   string objName = "RangeBox_" + TimeToString(t1, TIME_DATE);

   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, objName, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, objName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, objName, OBJPROP_FILL, true);
      ObjectSetInteger(0, objName, OBJPROP_BACK, true);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Helper: Count open positions for this EA                         |
//+------------------------------------------------------------------+
int GetOpenPositionCount()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Helper: Count pending orders for this EA                         |
//+------------------------------------------------------------------+
int GetPendingOrderCount()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Helper: Delete all pending orders for this EA                    |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            trade.OrderDelete(ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: Close all open positions for this EA                     |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            trade.PositionClose(ticket);
         }
      }
   }
}