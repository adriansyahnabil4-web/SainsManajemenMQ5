//+------------------------------------------------------------------+
//|                                                     EA14.mq5     |
//|                    Daily Time-Based Range Breakout EA            |
//|                         Pure MQL5 / MT5                          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Daily time-based range breakout Expert Advisor"
#property description "Pure MQL5 - no MT4 functions"

//--- Trading
#include <Trade/Trade.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+

//--- Range time
input group "Range Settings"

input int      InpRangeStartHour       = 8;
input int      InpRangeStartMinute     = 0;

input int      InpRangeEndHour         = 9;
input int      InpRangeEndMinute       = 0;

//--- Trading cutoff
input group "Trading Cutoff"

input int      InpCutoffHour           = 17;
input int      InpCutoffMinute         = 0;

//--- Trading
input group "Trade Settings"

input double   InpLots                 = 0.10;
input ulong    InpMagicNumber          = 140014;
input int      InpDeviationPoints      = 20;

input bool     InpAllowBuy             = true;
input bool     InpAllowSell            = true;

//--- Optional SL/TP
input group "Risk Management"

input int      InpStopLossPoints       = 0;
input int      InpTakeProfitPoints     = 0;

//--- Range breakout behavior
input group "Breakout Settings"

input bool     InpUsePendingOrders     = true;
input bool     InpUseMarketFallback    = true;

//--- Chart display
input group "Visual Settings"

input bool     InpDrawRange             = true;
input color    InpRangeColor            = clrDodgerBlue;
input ENUM_LINE_STYLE InpRangeStyle     = STYLE_SOLID;
input int      InpRangeWidth            = 1;
input bool     InpDrawRangeMidline      = true;
input color    InpMidlineColor          = clrSilver;

//--- Misc
input group "General"

input bool     InpPrintDebug            = true;


//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+

datetime g_dayStart       = 0;
datetime g_rangeStart     = 0;
datetime g_rangeEnd       = 0;
datetime g_cutoffTime    = 0;

double   g_rangeHigh      = 0.0;
double   g_rangeLow       = 0.0;

bool     g_rangeCreated   = false;
bool     g_ordersPlaced   = false;
bool     g_cutoffHandled  = false;

int      g_lastDayOfYear  = -1;


//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+

void DebugPrint(string message)
{
   if(InpPrintDebug)
      Print("[EA14] ", message);
}


//+------------------------------------------------------------------+
//| Normalize price                                                 |
//+------------------------------------------------------------------+

double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}


//+------------------------------------------------------------------+
//| Normalize volume                                                 |
//+------------------------------------------------------------------+

double NormalizeVolume(double volume)
{
   double minVolume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepVolume <= 0.0)
      return volume;

   volume = MathMax(minVolume, MathMin(maxVolume, volume));

   volume = MathFloor(volume / stepVolume) * stepVolume;

   int volumeDigits = 2;

   if(stepVolume == 1.0)
      volumeDigits = 0;
   else if(stepVolume == 0.1)
      volumeDigits = 1;
   else if(stepVolume == 0.01)
      volumeDigits = 2;

   return NormalizeDouble(volume, volumeDigits);
}


//+------------------------------------------------------------------+
//| Get today's midnight                                             |
//+------------------------------------------------------------------+

datetime GetDayStart(datetime currentTime)
{
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);

   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;

   return StructToTime(dt);
}


//+------------------------------------------------------------------+
//| Build today's session times                                      |
//+------------------------------------------------------------------+

bool BuildDailyTimes(datetime currentTime)
{
   g_dayStart = GetDayStart(currentTime);

   g_rangeStart =
      g_dayStart +
      InpRangeStartHour * 3600 +
      InpRangeStartMinute * 60;

   g_rangeEnd =
      g_dayStart +
      InpRangeEndHour * 3600 +
      InpRangeEndMinute * 60;

   g_cutoffTime =
      g_dayStart +
      InpCutoffHour * 3600 +
      InpCutoffMinute * 60;

   if(g_rangeEnd <= g_rangeStart)
   {
      Print("[EA14] ERROR: Range end time must be later than range start time.");
      return false;
   }

   if(g_cutoffTime <= g_rangeEnd)
   {
      Print("[EA14] ERROR: Cutoff time must be later than range end time.");
      return false;
   }

   return true;
}


//+------------------------------------------------------------------+
//| Reset daily state                                                |
//+------------------------------------------------------------------+

void ResetDailyState(datetime currentTime)
{
   BuildDailyTimes(currentTime);

   g_rangeHigh     = 0.0;
   g_rangeLow      = 0.0;

   g_rangeCreated  = false;
   g_ordersPlaced  = false;
   g_cutoffHandled = false;

   MqlDateTime dt;
   TimeToStruct(currentTime, dt);

   g_lastDayOfYear = dt.day_of_year;

   DebugPrint(
      "New trading day initialized. Range: " +
      TimeToString(g_rangeStart, TIME_MINUTES) +
      " - " +
      TimeToString(g_rangeEnd, TIME_MINUTES) +
      ", cutoff: " +
      TimeToString(g_cutoffTime, TIME_MINUTES)
   );
}


//+------------------------------------------------------------------+
//| Check for new trading day                                        |
//+------------------------------------------------------------------+

void CheckNewDay(datetime currentTime)
{
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);

   if(g_dayStart == 0)
   {
      ResetDailyState(currentTime);
      return;
   }

   if(dt.day_of_year != g_lastDayOfYear ||
      GetDayStart(currentTime) != g_dayStart)
   {
      ResetDailyState(currentTime);
   }
}


//+------------------------------------------------------------------+
//| Calculate range using M1 bars                                    |
//+------------------------------------------------------------------+

bool CalculateRange()
{
   MqlRates rates[];

   ArraySetAsSeries(rates, false);

   datetime calculationEnd = g_rangeEnd - 1;

   if(calculationEnd < g_rangeStart)
      return false;

   int copied = CopyRates(
      _Symbol,
      PERIOD_M1,
      g_rangeStart,
      calculationEnd,
      rates
   );

   if(copied <= 0)
   {
      DebugPrint(
         "Unable to retrieve M1 data for range. Error: " +
         IntegerToString(GetLastError())
      );

      return false;
   }

   double highest = -DBL_MAX;
   double lowest  = DBL_MAX;

   for(int i = 0; i < copied; i++)
   {
      if(rates[i].high > highest)
         highest = rates[i].high;

      if(rates[i].low < lowest)
         lowest = rates[i].low;
   }

   if(highest == -DBL_MAX || lowest == DBL_MAX)
      return false;

   g_rangeHigh = NormalizePrice(highest);
   g_rangeLow  = NormalizePrice(lowest);

   if(g_rangeHigh <= g_rangeLow)
      return false;

   return true;
}


//+------------------------------------------------------------------+
//| Object name                                                       |
//+------------------------------------------------------------------+

string GetRangeObjectName()
{
   return "EA14_RANGE_" + IntegerToString((long)g_dayStart);
}


string GetMidlineObjectName()
{
   return "EA14_MID_" + IntegerToString((long)g_dayStart);
}


//+------------------------------------------------------------------+
//| Draw range rectangle                                             |
//+------------------------------------------------------------------+

void DrawRange()
{
   if(!InpDrawRange)
      return;

   string name = GetRangeObjectName();

   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   if(!ObjectCreate(
      0,
      name,
      OBJ_RECTANGLE,
      0,
      g_rangeStart,
      g_rangeHigh,
      g_rangeEnd,
      g_rangeLow
   ))
   {
      DebugPrint(
         "Failed to create range rectangle. Error: " +
         IntegerToString(GetLastError())
      );
      return;
   }

   ObjectSetInteger(0, name, OBJPROP_COLOR, InpRangeColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, InpRangeStyle);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpRangeWidth);
   ObjectSetInteger(0, name, OBJPROP_FILL, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);

   //--- Midline
   if(InpDrawRangeMidline)
   {
      string midName = GetMidlineObjectName();

      if(ObjectFind(0, midName) >= 0)
         ObjectDelete(0, midName);

      double midpoint = NormalizePrice(
         (g_rangeHigh + g_rangeLow) / 2.0
      );

      if(ObjectCreate(
         0,
         midName,
         OBJ_TREND,
         0,
         g_rangeStart,
         midpoint,
         g_cutoffTime,
         midpoint
      ))
      {
         ObjectSetInteger(0, midName, OBJPROP_COLOR, InpMidlineColor);
         ObjectSetInteger(0, midName, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, midName, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, midName, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, midName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, midName, OBJPROP_HIDDEN, true);
      }
   }

   ChartRedraw(0);
}


//+------------------------------------------------------------------+
//| Check whether EA pending order exists                            |
//+------------------------------------------------------------------+

bool HasPendingOrder(ENUM_ORDER_TYPE requestedType)
{
   int total = OrdersTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);

      if(symbol != _Symbol)
         continue;

      ulong magic = (ulong)OrderGetInteger(ORDER_MAGIC);

      if(magic != InpMagicNumber)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type == requestedType)
         return true;
   }

   return false;
}


//+------------------------------------------------------------------+
//| Delete all EA pending orders                                     |
//+------------------------------------------------------------------+

void DeletePendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);

      if(symbol != _Symbol)
         continue;

      ulong magic = (ulong)OrderGetInteger(ORDER_MAGIC);

      if(magic != InpMagicNumber)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      bool isPending =
         type == ORDER_TYPE_BUY_LIMIT ||
         type == ORDER_TYPE_SELL_LIMIT ||
         type == ORDER_TYPE_BUY_STOP ||
         type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_STOP_LIMIT ||
         type == ORDER_TYPE_SELL_STOP_LIMIT;

      if(!isPending)
         continue;

      if(trade.OrderDelete(ticket))
      {
         DebugPrint(
            "Pending order deleted. Ticket: " +
            IntegerToString((long)ticket)
         );
      }
      else
      {
         DebugPrint(
            "Failed to delete pending order " +
            IntegerToString((long)ticket) +
            ". Retcode: " +
            IntegerToString((int)trade.ResultRetcode()) +
            " - " +
            trade.ResultRetcodeDescription()
         );
      }
   }
}


//+------------------------------------------------------------------+
//| Check if EA position exists                                      |
//+------------------------------------------------------------------+

bool HasOpenPosition(ENUM_POSITION_TYPE requestedType)
{
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);

      if(symbol != _Symbol)
         continue;

      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(magic != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == requestedType)
         return true;
   }

   return false;
}


//+------------------------------------------------------------------+
//| Check whether any EA position exists                            |
//+------------------------------------------------------------------+

bool HasAnyOpenPosition()
{
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);

      if(symbol != _Symbol)
         continue;

      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(magic != InpMagicNumber)
         continue;

      return true;
   }

   return false;
}


//+------------------------------------------------------------------+
//| Close all EA positions                                           |
//+------------------------------------------------------------------+

void CloseEAPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);

      if(symbol != _Symbol)
         continue;

      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(magic != InpMagicNumber)
         continue;

      if(trade.PositionClose(ticket))
      {
         DebugPrint(
            "Position closed at cutoff. Ticket: " +
            IntegerToString((long)ticket)
         );
      }
      else
      {
         DebugPrint(
            "Failed to close position " +
            IntegerToString((long)ticket) +
            ". Retcode: " +
            IntegerToString((int)trade.ResultRetcode()) +
            " - " +
            trade.ResultRetcodeDescription()
         );
      }
   }
}


//+------------------------------------------------------------------+
//| Calculate SL for BUY                                             |
//+------------------------------------------------------------------+

double CalculateBuySL(double entryPrice)
{
   if(InpStopLossPoints <= 0)
      return 0.0;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double sl =
      entryPrice -
      InpStopLossPoints * point;

   return NormalizePrice(sl);
}


//+------------------------------------------------------------------+
//| Calculate TP for BUY                                             |
//+------------------------------------------------------------------+

double CalculateBuyTP(double entryPrice)
{
   if(InpTakeProfitPoints <= 0)
      return 0.0;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double tp =
      entryPrice +
      InpTakeProfitPoints * point;

   return NormalizePrice(tp);
}


//+------------------------------------------------------------------+
//| Calculate SL for SELL                                            |
//+------------------------------------------------------------------+

double CalculateSellSL(double entryPrice)
{
   if(InpStopLossPoints <= 0)
      return 0.0;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double sl =
      entryPrice +
      InpStopLossPoints * point;

   return NormalizePrice(sl);
}


//+------------------------------------------------------------------+
//| Calculate TP for SELL                                            |
//+------------------------------------------------------------------+

double CalculateSellTP(double entryPrice)
{
   if(InpTakeProfitPoints <= 0)
      return 0.0;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double tp =
      entryPrice -
      InpTakeProfitPoints * point;

   return NormalizePrice(tp);
}


//+------------------------------------------------------------------+
//| Check minimum stop distance                                      |
//+------------------------------------------------------------------+

bool IsValidPendingPrice(
   ENUM_ORDER_TYPE type,
   double price
)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   long stopsLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   double point =
      SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double minimumDistance =
      stopsLevel * point;

   if(type == ORDER_TYPE_BUY_STOP)
   {
      if(price <= tick.ask)
         return false;

      if((price - tick.ask) < minimumDistance)
         return false;
   }

   if(type == ORDER_TYPE_SELL_STOP)
   {
      if(price >= tick.bid)
         return false;

      if((tick.bid - price) < minimumDistance)
         return false;
   }

   return true;
}


//+------------------------------------------------------------------+
//| Place Buy Stop                                                   |
//+------------------------------------------------------------------+

bool PlaceBuyStop()
{
   if(!InpAllowBuy || !InpUsePendingOrders)
      return false;

   if(HasPendingOrder(ORDER_TYPE_BUY_STOP))
      return true;

   if(HasOpenPosition(POSITION_TYPE_BUY))
      return true;

   double price = NormalizePrice(g_rangeHigh);

   if(!IsValidPendingPrice(ORDER_TYPE_BUY_STOP, price))
   {
      DebugPrint(
         "Buy Stop cannot be placed at range high. "
         "Market fallback will be used if breakout occurs."
      );

      return false;
   }

   double sl = CalculateBuySL(price);
   double tp = CalculateBuyTP(price);

   double volume = NormalizeVolume(InpLots);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool result =
      trade.BuyStop(
         volume,
         price,
         _Symbol,
         sl,
         tp,
         ORDER_TIME_GTC,
         0,
         "EA14 Range Buy"
      );

   if(!result)
   {
      DebugPrint(
         "Buy Stop failed. Retcode: " +
         IntegerToString((int)trade.ResultRetcode()) +
         " - " +
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   DebugPrint(
      "Buy Stop placed at " +
      DoubleToString(price, _Digits)
   );

   return true;
}


//+------------------------------------------------------------------+
//| Place Sell Stop                                                  |
//+------------------------------------------------------------------+

bool PlaceSellStop()
{
   if(!InpAllowSell || !InpUsePendingOrders)
      return false;

   if(HasPendingOrder(ORDER_TYPE_SELL_STOP))
      return true;

   if(HasOpenPosition(POSITION_TYPE_SELL))
      return true;

   double price = NormalizePrice(g_rangeLow);

   if(!IsValidPendingPrice(ORDER_TYPE_SELL_STOP, price))
   {
      DebugPrint(
         "Sell Stop cannot be placed at range low. "
         "Market fallback will be used if breakout occurs."
      );

      return false;
   }

   double sl = CalculateSellSL(price);
   double tp = CalculateSellTP(price);

   double volume = NormalizeVolume(InpLots);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool result =
      trade.SellStop(
         volume,
         price,
         _Symbol,
         sl,
         tp,
         ORDER_TIME_GTC,
         0,
         "EA14 Range Sell"
      );

   if(!result)
   {
      DebugPrint(
         "Sell Stop failed. Retcode: " +
         IntegerToString((int)trade.ResultRetcode()) +
         " - " +
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   DebugPrint(
      "Sell Stop placed at " +
      DoubleToString(price, _Digits)
   );

   return true;
}


//+------------------------------------------------------------------+
//| Open market BUY                                                  |
//+------------------------------------------------------------------+

bool OpenMarketBuy()
{
   if(!InpAllowBuy || !InpUseMarketFallback)
      return false;

   if(HasOpenPosition(POSITION_TYPE_BUY))
      return true;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   if(tick.ask <= g_rangeHigh)
      return false;

   double entry = tick.ask;

   double sl = CalculateBuySL(entry);
   double tp = CalculateBuyTP(entry);

   double volume = NormalizeVolume(InpLots);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool result =
      trade.Buy(
         volume,
         _Symbol,
         0.0,
         sl,
         tp,
         "EA14 Breakout Buy"
      );

   if(!result)
   {
      DebugPrint(
         "Market BUY failed. Retcode: " +
         IntegerToString((int)trade.ResultRetcode()) +
         " - " +
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   DebugPrint(
      "Market BUY opened after breakout. Ask: " +
      DoubleToString(entry, _Digits)
   );

   return true;
}


//+------------------------------------------------------------------+
//| Open market SELL                                                 |
//+------------------------------------------------------------------+

bool OpenMarketSell()
{
   if(!InpAllowSell || !InpUseMarketFallback)
      return false;

   if(HasOpenPosition(POSITION_TYPE_SELL))
      return true;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   if(tick.bid >= g_rangeLow)
      return false;

   double entry = tick.bid;

   double sl = CalculateSellSL(entry);
   double tp = CalculateSellTP(entry);

   double volume = NormalizeVolume(InpLots);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool result =
      trade.Sell(
         volume,
         _Symbol,
         0.0,
         sl,
         tp,
         "EA14 Breakout Sell"
      );

   if(!result)
   {
      DebugPrint(
         "Market SELL failed. Retcode: " +
         IntegerToString((int)trade.ResultRetcode()) +
         " - " +
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   DebugPrint(
      "Market SELL opened after breakout. Bid: " +
      DoubleToString(entry, _Digits)
   );

   return true;
}


//+------------------------------------------------------------------+
//| Place initial pending orders                                     |
//+------------------------------------------------------------------+

void PlaceRangeOrders()
{
   if(!g_rangeCreated)
      return;

   if(g_ordersPlaced)
      return;

   //--- If price already broke out before orders could be placed,
   //--- use market entry instead.
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   bool buyBreakout =
      InpAllowBuy &&
      tick.ask > g_rangeHigh;

   bool sellBreakout =
      InpAllowSell &&
      tick.bid < g_rangeLow;

   if(buyBreakout)
   {
      DeletePendingOrders();

      OpenMarketBuy();

      g_ordersPlaced = true;
      return;
   }

   if(sellBreakout)
   {
      DeletePendingOrders();

      OpenMarketSell();

      g_ordersPlaced = true;
      return;
   }

   //--- Normal pending order placement
   if(InpUsePendingOrders)
   {
      PlaceBuyStop();
      PlaceSellStop();
   }

   g_ordersPlaced = true;
}


//+------------------------------------------------------------------+
//| Handle breakout fallback                                        |
//+------------------------------------------------------------------+

void CheckMarketBreakout()
{
   if(!g_rangeCreated)
      return;

   if(!InpUseMarketFallback)
      return;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   //--- BUY breakout
   if(InpAllowBuy && tick.ask > g_rangeHigh)
   {
      // If there is already a buy position, nothing to do.
      if(HasOpenPosition(POSITION_TYPE_BUY))
         return;

      // If a Buy Stop exists, allow it to trigger normally.
      if(HasPendingOrder(ORDER_TYPE_BUY_STOP))
         return;

      // Otherwise use market fallback.
      OpenMarketBuy();
      return;
   }

   //--- SELL breakout
   if(InpAllowSell && tick.bid < g_rangeLow)
   {
      if(HasOpenPosition(POSITION_TYPE_SELL))
         return;

      // If a Sell Stop exists, allow it to trigger normally.
      if(HasPendingOrder(ORDER_TYPE_SELL_STOP))
         return;

      // Otherwise use market fallback.
      OpenMarketSell();
      return;
   }
}


//+------------------------------------------------------------------+
//| Handle cutoff                                                   |
//+------------------------------------------------------------------+

void HandleCutoff(datetime currentTime)
{
   if(g_cutoffHandled)
      return;

   if(currentTime < g_cutoffTime)
      return;

   DebugPrint("Cutoff reached. Removing pending orders and closing positions.");

   DeletePendingOrders();
   CloseEAPositions();

   g_cutoffHandled = true;
}


//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+

int OnInit()
{
   //--- Validate symbol
   if(!SymbolSelect(_Symbol, true))
   {
      Print("[EA14] ERROR: Unable to select symbol ", _Symbol);
      return INIT_FAILED;
   }

   //--- Validate inputs
   if(InpRangeStartHour < 0 ||
      InpRangeStartHour > 23 ||
      InpRangeEndHour < 0 ||
      InpRangeEndHour > 23 ||
      InpCutoffHour < 0 ||
      InpCutoffHour > 23)
   {
      Print("[EA14] ERROR: Invalid hour input.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpRangeStartMinute < 0 ||
      InpRangeStartMinute > 59 ||
      InpRangeEndMinute < 0 ||
      InpRangeEndMinute > 59 ||
      InpCutoffMinute < 0 ||
      InpCutoffMinute > 59)
   {
      Print("[EA14] ERROR: Invalid minute input.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpLots <= 0.0)
   {
      Print("[EA14] ERROR: Lot size must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpMagicNumber == 0)
   {
      Print("[EA14] ERROR: Magic number must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Configure trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- Initialize daily state
   datetime now = TimeCurrent();

   if(!BuildDailyTimes(now))
      return INIT_PARAMETERS_INCORRECT;

   ResetDailyState(now);

   DebugPrint("EA14 initialized on " + _Symbol);

   DebugPrint(
      "Broker/server time: " +
      TimeToString(now, TIME_DATE | TIME_SECONDS)
   );

   return INIT_SUCCEEDED;
}


//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+

void OnDeinit(const int reason)
{
   //--- Intentionally do not delete the range objects.
   //--- This allows historical ranges to remain visible.
   DebugPrint(
      "EA14 deinitialized. Reason: " +
      IntegerToString(reason)
   );
}


//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+

void OnTick()
{
   datetime now = TimeCurrent();

   //--- Detect new trading day
   CheckNewDay(now);

   //--- Cutoff has priority
   HandleCutoff(now);

   if(g_cutoffHandled)
      return;

   //--- Before range starts
   if(now < g_rangeStart)
      return;

   //--- During range formation
   if(now >= g_rangeStart && now < g_rangeEnd)
   {
      // Do not calculate final range yet.
      return;
   }

   //--- Range period has finished
   if(now >= g_rangeEnd && !g_rangeCreated)
   {
      if(CalculateRange())
      {
         g_rangeCreated = true;

         DebugPrint(
            "Range created. HIGH = " +
            DoubleToString(g_rangeHigh, _Digits) +
            " | LOW = " +
            DoubleToString(g_rangeLow, _Digits)
         );

         DrawRange();
      }
      else
      {
         DebugPrint("Range calculation failed. Retrying on next tick.");
         return;
      }
   }

   //--- Place orders after range creation
   if(g_rangeCreated && !g_ordersPlaced)
   {
      PlaceRangeOrders();
   }

   //--- Check market fallback
   if(g_rangeCreated)
   {
      CheckMarketBreakout();
   }
}


//+------------------------------------------------------------------+
//| Trade transaction                                                |
//+------------------------------------------------------------------+

void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result
)
{
   //--- This function is intentionally lightweight.
   //--- It provides useful diagnostic information when EA14
   //--- receives a trade transaction.

   if(trans.symbol != _Symbol)
      return;

   if(InpPrintDebug)
   {
      if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      {
         DebugPrint(
            "Deal executed. Deal ticket: " +
            IntegerToString((long)trans.deal)
         );
      }
      else if(trans.type == TRADE_TRANSACTION_ORDER_ADD)
      {
         DebugPrint(
            "Order added. Order ticket: " +
            IntegerToString((long)trans.order)
         );
      }
      else if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
      {
         DebugPrint(
            "Order deleted. Order ticket: " +
            IntegerToString((long)trans.order)
         );
      }
   }
}
//+------------------------------------------------------------------+