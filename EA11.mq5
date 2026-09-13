//+------------------------------------------------------------------+
//|                                                   EA11.mq5       |
//|                    Daily Range Breakout Expert Advisor           |
//|                         Pure MQL5 / MT5                          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Daily Range Breakout EA"
#property description "Range -> Buy Stop/Sell Stop -> Opposite Range SL"
#property description "Risk-based position sizing with Magic Number isolation"

//--- Trading
#include <Trade/Trade.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//| ENUMS                                                            |
//+------------------------------------------------------------------+
enum ENUM_RISK_MODE
  {
   RISK_FIXED_MONEY = 0,   // Fixed monetary risk
   RISK_PERCENTAGE  = 1    // Percentage of equity
  };

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+

//--- General
input ulong          InpMagicNumber       = 110011;       // Magic Number
input string         InpTradeComment      = "EA11";       // Trade Comment

//--- Range
input string         InpRangeStartTime    = "03:00";      // Range Start (Broker Time)
input string         InpRangeEndTime      = "06:00";      // Range End (Broker Time)

//--- Daily cleanup
input string         InpCloseTime         = "18:00";      // Close/Delete Time (Broker Time)

//--- Risk management
input ENUM_RISK_MODE InpRiskMode          = RISK_PERCENTAGE; // Risk Mode
input double         InpRiskPercentage    = 1.0;          // Risk % of Equity
input double         InpRiskMoney         = 100.0;        // Fixed Risk Money

//--- Take Profit
input double         InpTPMultiplier       = 2.0;          // TP = Range x Multiplier (0 = disabled)

//--- Optional range filters
input double         InpMinRangePoints    = 0.0;          // Minimum Range (points, 0 = disabled)
input double         InpMaxRangePoints    = 0.0;          // Maximum Range (points, 0 = disabled)

//--- Visual
input bool           InpDrawRange         = true;         // Draw Range
input bool           InpDrawRangeBox      = true;         // Draw Range Rectangle
input bool           InpDrawRangeLines    = true;         // Draw High/Low Lines
input color          InpRangeBoxColor     = clrAliceBlue; // Range Box Color
input color          InpHighLineColor     = clrLimeGreen; // High Line Color
input color          InpLowLineColor      = clrTomato;    // Low Line Color

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+

int      g_start_minutes = 0;
int      g_end_minutes   = 0;
int      g_close_minutes = 0;

int      g_day_key = -1;

double   g_range_high = 0.0;
double   g_range_low  = 0.0;

bool     g_range_ready = false;
bool     g_orders_placed = false;
bool     g_day_finished = false;

//+------------------------------------------------------------------+
//| STRUCT FOR TIME                                                  |
//+------------------------------------------------------------------+
struct STimeParts
  {
   int hour;
   int minute;
  };

//+------------------------------------------------------------------+
//| Parse HH:MM                                                      |
//+------------------------------------------------------------------+
bool ParseTimeString(const string value, int &minutes)
  {
   string parts[];

   int count = StringSplit(value, ':', parts);

   if(count != 2)
      return false;

   int hour   = (int)StringToInteger(parts[0]);
   int minute = (int)StringToInteger(parts[1]);

   if(hour < 0 || hour > 23)
      return false;

   if(minute < 0 || minute > 59)
      return false;

   minutes = hour * 60 + minute;

   return true;
  }

//+------------------------------------------------------------------+
//| Get current broker time                                           |
//+------------------------------------------------------------------+
datetime CurrentServerTime()
  {
   return TimeTradeServer();
  }

//+------------------------------------------------------------------+
//| Get day key                                                       |
//+------------------------------------------------------------------+
int GetDayKey(const datetime time_value)
  {
   MqlDateTime dt;

   if(!TimeToStruct(time_value, dt))
      return -1;

   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

//+------------------------------------------------------------------+
//| Get today's midnight                                              |
//+------------------------------------------------------------------+
datetime GetDayStart(const datetime time_value)
  {
   MqlDateTime dt;

   if(!TimeToStruct(time_value, dt))
      return 0;

   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;

   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
//| Convert minutes to today's datetime                              |
//+------------------------------------------------------------------+
datetime TimeToday(const datetime current_time, const int minutes)
  {
   datetime day_start = GetDayStart(current_time);

   return day_start + minutes * 60;
  }

//+------------------------------------------------------------------+
//| Check if time is inside range period                             |
//+------------------------------------------------------------------+
bool IsInsideRangePeriod(const datetime current_time)
  {
   int now_minutes = 0;

   MqlDateTime dt;

   if(!TimeToStruct(current_time, dt))
      return false;

   now_minutes = dt.hour * 60 + dt.min;

   return (now_minutes >= g_start_minutes &&
           now_minutes < g_end_minutes);
  }

//+------------------------------------------------------------------+
//| Check if range period has ended                                  |
//+------------------------------------------------------------------+
bool IsRangePeriodFinished(const datetime current_time)
  {
   MqlDateTime dt;

   if(!TimeToStruct(current_time, dt))
      return false;

   int now_minutes = dt.hour * 60 + dt.min;

   return now_minutes >= g_end_minutes;
  }

//+------------------------------------------------------------------+
//| Check cleanup time                                                |
//+------------------------------------------------------------------+
bool IsCloseTimeReached(const datetime current_time)
  {
   MqlDateTime dt;

   if(!TimeToStruct(current_time, dt))
      return false;

   int now_minutes = dt.hour * 60 + dt.min;

   return now_minutes >= g_close_minutes;
  }

//+------------------------------------------------------------------+
//| Normalize price                                                   |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
  {
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
  }

//+------------------------------------------------------------------+
//| Normalize volume                                                  |
//+------------------------------------------------------------------+
double NormalizeVolume(const double volume)
  {
   double min_volume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_volume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step_volume <= 0.0)
      return 0.0;

   double result = volume;

   result = MathMax(result, min_volume);
   result = MathMin(result, max_volume);

   result = MathFloor(result / step_volume) * step_volume;

   if(result < min_volume)
      return 0.0;

   int volume_digits = 0;

   double step_temp = step_volume;

   while(step_temp < 1.0 && volume_digits < 8)
     {
      step_temp *= 10.0;
      volume_digits++;
     }

   return NormalizeDouble(result, volume_digits);
  }

//+------------------------------------------------------------------+
//| Calculate risk money                                              |
//+------------------------------------------------------------------+
double GetRiskMoney()
  {
   if(InpRiskMode == RISK_FIXED_MONEY)
      return MathMax(0.0, InpRiskMoney);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity <= 0.0)
      return 0.0;

   return equity * InpRiskPercentage / 100.0;
  }

//+------------------------------------------------------------------+
//| Calculate volume from risk                                        |
//+------------------------------------------------------------------+
double CalculateRiskVolume(const ENUM_ORDER_TYPE order_type,
                           const double entry_price,
                           const double stop_price)
  {
   double risk_money = GetRiskMoney();

   if(risk_money <= 0.0)
      return 0.0;

   if(entry_price <= 0.0 || stop_price <= 0.0)
      return 0.0;

   double price_distance = MathAbs(entry_price - stop_price);

   if(price_distance <= 0.0)
      return 0.0;

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value_loss = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);

   if(tick_value_loss <= 0.0)
      tick_value_loss = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tick_size <= 0.0 || tick_value_loss <= 0.0)
      return 0.0;

   // Loss for one lot at the specified SL distance
   double loss_per_lot = (price_distance / tick_size) * tick_value_loss;

   if(loss_per_lot <= 0.0)
      return 0.0;

   double volume = risk_money / loss_per_lot;

   return NormalizeVolume(volume);
  }

//+------------------------------------------------------------------+
//| Check if price distance satisfies stops level                     |
//+------------------------------------------------------------------+
bool IsValidStopDistance(const ENUM_ORDER_TYPE order_type,
                         const double entry_price,
                         const double stop_price,
                         const double take_profit)
  {
   long stops_level_points =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   double minimum_distance =
      stops_level_points * _Point;

   if(minimum_distance <= 0.0)
      return true;

   if(order_type == ORDER_TYPE_BUY_STOP)
     {
      if(entry_price - stop_price < minimum_distance)
         return false;

      if(take_profit > 0.0 &&
         take_profit - entry_price < minimum_distance)
         return false;
     }
   else
   if(order_type == ORDER_TYPE_SELL_STOP)
     {
      if(stop_price - entry_price < minimum_distance)
         return false;

      if(take_profit > 0.0 &&
         entry_price - take_profit < minimum_distance)
         return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Get current day's range using M1 bars                            |
//+------------------------------------------------------------------+
bool CalculateDailyRange()
  {
   datetime now = CurrentServerTime();

   if(now <= 0)
      return false;

   datetime range_start = TimeToday(now, g_start_minutes);
   datetime range_end   = TimeToday(now, g_end_minutes);

   if(range_end <= range_start)
      return false;

   MqlRates rates[];

   ArraySetAsSeries(rates, false);

   int copied = CopyRates(_Symbol,
                          PERIOD_M1,
                          range_start,
                          range_end - 1,
                          rates);

   if(copied <= 0)
      return false;

   double highest = -DBL_MAX;
   double lowest  = DBL_MAX;

   for(int i = 0; i < copied; i++)
     {
      if(rates[i].time < range_start)
         continue;

      if(rates[i].time >= range_end)
         continue;

      if(rates[i].high > highest)
         highest = rates[i].high;

      if(rates[i].low < lowest)
         lowest = rates[i].low;
     }

   if(highest == -DBL_MAX || lowest == DBL_MAX)
      return false;

   if(highest <= lowest)
      return false;

   g_range_high = NormalizePrice(highest);
   g_range_low  = NormalizePrice(lowest);

   return true;
  }

//+------------------------------------------------------------------+
//| Draw horizontal line                                             |
//+------------------------------------------------------------------+
void DrawHorizontalLine(const string name,
                        const double price,
                        const color line_color)
  {
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   if(!ObjectCreate(0,
                   name,
                   OBJ_HLINE,
                   0,
                   0,
                   price))
      return;

   ObjectSetInteger(0, name, OBJPROP_COLOR, line_color);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
  }

//+------------------------------------------------------------------+
//| Draw range rectangle                                             |
//+------------------------------------------------------------------+
void DrawRangeRectangle()
  {
   datetime now = CurrentServerTime();

   datetime start_time = TimeToday(now, g_start_minutes);
   datetime end_time   = TimeToday(now, g_end_minutes);

   string name = "EA11_RANGE_" + IntegerToString(g_day_key);

   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   if(!ObjectCreate(0,
                   name,
                   OBJ_RECTANGLE,
                   0,
                   start_time,
                   g_range_high,
                   end_time,
                   g_range_low))
      return;

   ObjectSetInteger(0, name, OBJPROP_COLOR, InpRangeBoxColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
  }

//+------------------------------------------------------------------+
//| Draw current range                                               |
//+------------------------------------------------------------------+
void DrawRange()
  {
   if(!InpDrawRange)
      return;

   string high_name =
      "EA11_HIGH_" + IntegerToString(g_day_key);

   string low_name =
      "EA11_LOW_" + IntegerToString(g_day_key);

   if(InpDrawRangeLines)
     {
      DrawHorizontalLine(high_name,
                         g_range_high,
                         InpHighLineColor);

      DrawHorizontalLine(low_name,
                         g_range_low,
                         InpLowLineColor);
     }

   if(InpDrawRangeBox)
      DrawRangeRectangle();

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Delete today's visual objects                                    |
//+------------------------------------------------------------------+
void DeleteRangeObjects(const int day_key)
  {
   string high_name =
      "EA11_HIGH_" + IntegerToString(day_key);

   string low_name =
      "EA11_LOW_" + IntegerToString(day_key);

   string box_name =
      "EA11_RANGE_" + IntegerToString(day_key);

   ObjectDelete(0, high_name);
   ObjectDelete(0, low_name);
   ObjectDelete(0, box_name);
  }

//+------------------------------------------------------------------+
//| Check whether position belongs to EA                             |
//+------------------------------------------------------------------+
bool IsOurPosition(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   long magic    = PositionGetInteger(POSITION_MAGIC);

   if(symbol != _Symbol)
      return false;

   if((ulong)magic != InpMagicNumber)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Check whether order belongs to EA                                |
//+------------------------------------------------------------------+
bool IsOurOrder(const ulong ticket)
  {
   if(!OrderSelect(ticket))
      return false;

   string symbol = OrderGetString(ORDER_SYMBOL);
   long magic    = OrderGetInteger(ORDER_MAGIC);

   if(symbol != _Symbol)
      return false;

   if((ulong)magic != InpMagicNumber)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Count our positions                                              |
//+------------------------------------------------------------------+
int CountOurPositions()
  {
   int count = 0;

   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(IsOurPosition(ticket))
         count++;
     }

   return count;
  }

//+------------------------------------------------------------------+
//| Count our pending orders                                         |
//+------------------------------------------------------------------+
int CountOurPendingOrders()
  {
   int count = 0;

   int total = OrdersTotal();

   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!IsOurOrder(ticket))
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type == ORDER_TYPE_BUY_STOP ||
         type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_LIMIT ||
         type == ORDER_TYPE_SELL_LIMIT ||
         type == ORDER_TYPE_BUY_STOP_LIMIT ||
         type == ORDER_TYPE_SELL_STOP_LIMIT)
         count++;
     }

   return count;
  }

//+------------------------------------------------------------------+
//| Delete all our pending orders                                    |
//+------------------------------------------------------------------+
void DeleteOurPendingOrders()
  {
   int total = OrdersTotal();

   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!IsOurOrder(ticket))
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      bool pending =
         type == ORDER_TYPE_BUY_STOP ||
         type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_LIMIT ||
         type == ORDER_TYPE_SELL_LIMIT ||
         type == ORDER_TYPE_BUY_STOP_LIMIT ||
         type == ORDER_TYPE_SELL_STOP_LIMIT;

      if(!pending)
         continue;

      if(!trade.OrderDelete(ticket))
        {
         Print("EA11: Failed to delete order #",
               ticket,
               " | Retcode=",
               trade.ResultRetcode(),
               " | ",
               trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Close all our positions                                          |
//+------------------------------------------------------------------+
void CloseOurPositions()
  {
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!IsOurPosition(ticket))
         continue;

      if(!trade.PositionClose(ticket))
        {
         Print("EA11: Failed to close position #",
               ticket,
               " | Retcode=",
               trade.ResultRetcode(),
               " | ",
               trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Cleanup all EA trades/orders                                     |
//+------------------------------------------------------------------+
void PerformDailyCleanup()
  {
   DeleteOurPendingOrders();
   CloseOurPositions();

   g_day_finished = true;
   g_orders_placed = false;

   Print("EA11: Daily cleanup completed.");
  }

//+------------------------------------------------------------------+
//| Detect whether our position exists                               |
//+------------------------------------------------------------------+
bool HasOurPosition()
  {
   return CountOurPositions() > 0;
  }

//+------------------------------------------------------------------+
//| Place breakout orders                                            |
//+------------------------------------------------------------------+
bool PlaceBreakoutOrders()
  {
   if(g_range_high <= g_range_low)
      return false;

   double range_size = g_range_high - g_range_low;

   double range_points = range_size / _Point;

   if(InpMinRangePoints > 0.0 &&
      range_points < InpMinRangePoints)
     {
      Print("EA11: Range too small. Range=",
            DoubleToString(range_points, 1),
            " points.");

      return false;
     }

   if(InpMaxRangePoints > 0.0 &&
      range_points > InpMaxRangePoints)
     {
      Print("EA11: Range too large. Range=",
            DoubleToString(range_points, 1),
            " points.");

      return false;
     }

   // Prevent duplicates
   if(HasOurPosition())
     {
      g_orders_placed = true;
      return true;
     }

   if(CountOurPendingOrders() > 0)
     {
      g_orders_placed = true;
      return true;
     }

   double buy_entry  = NormalizePrice(g_range_high);
   double buy_sl     = NormalizePrice(g_range_low);

   double sell_entry = NormalizePrice(g_range_low);
   double sell_sl    = NormalizePrice(g_range_high);

   double buy_tp  = 0.0;
   double sell_tp = 0.0;

   if(InpTPMultiplier > 0.0)
     {
      buy_tp =
         NormalizePrice(buy_entry +
                        range_size * InpTPMultiplier);

      sell_tp =
         NormalizePrice(sell_entry -
                        range_size * InpTPMultiplier);
     }

   //--- Validate pending order distances
   if(!IsValidStopDistance(ORDER_TYPE_BUY_STOP,
                           buy_entry,
                           buy_sl,
                           buy_tp))
     {
      Print("EA11: Buy Stop SL/TP distance is invalid.");

      return false;
     }

   if(!IsValidStopDistance(ORDER_TYPE_SELL_STOP,
                           sell_entry,
                           sell_sl,
                           sell_tp))
     {
      Print("EA11: Sell Stop SL/TP distance is invalid.");

      return false;
     }

   //--- Calculate volumes
   double buy_volume =
      CalculateRiskVolume(ORDER_TYPE_BUY_STOP,
                          buy_entry,
                          buy_sl);

   double sell_volume =
      CalculateRiskVolume(ORDER_TYPE_SELL_STOP,
                          sell_entry,
                          sell_sl);

   if(buy_volume <= 0.0)
     {
      Print("EA11: Invalid Buy Stop volume.");

      return false;
     }

   if(sell_volume <= 0.0)
     {
      Print("EA11: Invalid Sell Stop volume.");

      return false;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool buy_result = trade.BuyStop(buy_volume,
                                   buy_entry,
                                   _Symbol,
                                   buy_sl,
                                   buy_tp,
                                   ORDER_TIME_DAY,
                                   0,
                                   InpTradeComment + "_BUY");

   if(!buy_result)
     {
      Print("EA11: Buy Stop failed. Retcode=",
            trade.ResultRetcode(),
            " | ",
            trade.ResultRetcodeDescription());

      return false;
     }

   Print("EA11: Buy Stop placed. Ticket=",
         trade.ResultOrder(),
         " Volume=",
         DoubleToString(buy_volume, 2),
         " Entry=",
         DoubleToString(buy_entry, _Digits),
         " SL=",
         DoubleToString(buy_sl, _Digits),
         " TP=",
         DoubleToString(buy_tp, _Digits));

   bool sell_result = trade.SellStop(sell_volume,
                                     sell_entry,
                                     _Symbol,
                                     sell_sl,
                                     sell_tp,
                                     ORDER_TIME_DAY,
                                     0,
                                     InpTradeComment + "_SELL");

   if(!sell_result)
     {
      Print("EA11: Sell Stop failed. Retcode=",
            trade.ResultRetcode(),
            " | ",
            trade.ResultRetcodeDescription());

      // Important:
      // If only Buy Stop exists, remove it so the strategy
      // does not operate with an incomplete hedge.
      DeleteOurPendingOrders();

      return false;
     }

   Print("EA11: Sell Stop placed. Ticket=",
         trade.ResultOrder(),
         " Volume=",
         DoubleToString(sell_volume, 2),
         " Entry=",
         DoubleToString(sell_entry, _Digits),
         " SL=",
         DoubleToString(sell_sl, _Digits),
         " TP=",
         DoubleToString(sell_tp, _Digits));

   g_orders_placed = true;

   return true;
  }

//+------------------------------------------------------------------+
//| Delete opposite pending order after execution                   |
//+------------------------------------------------------------------+
void HandleTriggeredPosition()
  {
   if(!HasOurPosition())
      return;

   // If our position exists, no pending order should remain.
   DeleteOurPendingOrders();

   g_orders_placed = true;
  }

//+------------------------------------------------------------------+
//| Recover today's existing state                                  |
//+------------------------------------------------------------------+
void RecoverState()
  {
   datetime now = CurrentServerTime();

   if(now <= 0)
      return;

   int today = GetDayKey(now);

   if(today <= 0)
      return;

   g_day_key = today;

   if(IsCloseTimeReached(now))
     {
      g_day_finished = true;
      return;
     }

   // If a position already exists, the breakout has happened.
   if(HasOurPosition())
     {
      g_orders_placed = true;
      g_range_ready = true;
      return;
     }

   // If pending orders already exist, don't duplicate them.
   if(CountOurPendingOrders() > 0)
     {
      g_orders_placed = true;
      g_range_ready = true;
      return;
     }

   // If the range period is over, reconstruct the range.
   if(IsRangePeriodFinished(now))
     {
      if(CalculateDailyRange())
        {
         g_range_ready = true;

         if(InpDrawRange)
            DrawRange();
        }

      return;
     }

   // If currently inside range period, calculate what is available.
   if(IsInsideRangePeriod(now))
     {
      if(CalculateDailyRange())
        {
         g_range_ready = true;

         if(InpDrawRange)
            DrawRange();
        }
     }
  }

//+------------------------------------------------------------------+
//| Process new trading day                                         |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   datetime now = CurrentServerTime();

   if(now <= 0)
      return;

   int today = GetDayKey(now);

   if(today <= 0)
      return;

   if(g_day_key == -1)
     {
      g_day_key = today;
      return;
     }

   if(today == g_day_key)
      return;

   // Delete old visual objects.
   DeleteRangeObjects(g_day_key);

   // Reset state.
   g_day_key = today;

   g_range_high = 0.0;
   g_range_low = 0.0;

   g_range_ready = false;
   g_orders_placed = false;
   g_day_finished = false;

   Print("EA11: New trading day detected. Day=",
         IntegerToString(g_day_key));
  }

//+------------------------------------------------------------------+
//| Main strategy processing                                        |
//+------------------------------------------------------------------+
void ProcessStrategy()
  {
   datetime now = CurrentServerTime();

   if(now <= 0)
      return;

   //--- Daily cleanup
   if(IsCloseTimeReached(now))
     {
      if(!g_day_finished)
         PerformDailyCleanup();

      return;
     }

   //--- Don't trade after daily cleanup
   if(g_day_finished)
      return;

   //--- If position has triggered, delete opposite pending order
   if(HasOurPosition())
     {
      HandleTriggeredPosition();
      return;
     }

   //--- If orders already exist, nothing else to do
   if(CountOurPendingOrders() > 0)
     {
      g_orders_placed = true;
      return;
     }

   //--- Range formation
   if(IsInsideRangePeriod(now))
     {
      if(CalculateDailyRange())
        {
         g_range_ready = true;

         if(InpDrawRange)
            DrawRange();
        }

      return;
     }

   //--- Wait until range is finished
   if(!IsRangePeriodFinished(now))
      return;

   //--- Calculate final range
   if(!g_range_ready)
     {
      if(!CalculateDailyRange())
         return;

      g_range_ready = true;

      if(InpDrawRange)
         DrawRange();
     }

   //--- Place orders
   if(!g_orders_placed)
      PlaceBreakoutOrders();
  }

//+------------------------------------------------------------------+
//| Validate inputs                                                  |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(g_start_minutes < 0 ||
      g_end_minutes < 0 ||
      g_close_minutes < 0)
      return false;

   // This implementation expects start < end within the same day.
   if(g_start_minutes >= g_end_minutes)
     {
      Print("EA11 ERROR: RangeStartTime must be earlier than RangeEndTime.");
      return false;
     }

   if(InpRiskMode == RISK_PERCENTAGE)
     {
      if(InpRiskPercentage <= 0.0)
        {
         Print("EA11 ERROR: RiskPercentage must be > 0.");
         return false;
        }
     }
   else
     {
      if(InpRiskMoney <= 0.0)
        {
         Print("EA11 ERROR: RiskMoney must be > 0.");
         return false;
        }
     }

   if(InpTPMultiplier < 0.0)
     {
      Print("EA11 ERROR: TPMultiplier cannot be negative.");
      return false;
     }

   if(InpMinRangePoints < 0.0)
     {
      Print("EA11 ERROR: MinRangePoints cannot be negative.");
      return false;
     }

   if(InpMaxRangePoints < 0.0)
     {
      Print("EA11 ERROR: MaxRangePoints cannot be negative.");
      return false;
     }

   if(InpMinRangePoints > 0.0 &&
      InpMaxRangePoints > 0.0 &&
      InpMinRangePoints > InpMaxRangePoints)
     {
      Print("EA11 ERROR: MinRangePoints > MaxRangePoints.");
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Parse times
   if(!ParseTimeString(InpRangeStartTime,
                       g_start_minutes))
     {
      Print("EA11 ERROR: Invalid RangeStartTime: ",
            InpRangeStartTime);

      return INIT_PARAMETERS_INCORRECT;
     }

   if(!ParseTimeString(InpRangeEndTime,
                       g_end_minutes))
     {
      Print("EA11 ERROR: Invalid RangeEndTime: ",
            InpRangeEndTime);

      return INIT_PARAMETERS_INCORRECT;
     }

   if(!ParseTimeString(InpCloseTime,
                       g_close_minutes))
     {
      Print("EA11 ERROR: Invalid CloseTime: ",
            InpCloseTime);

      return INIT_PARAMETERS_INCORRECT;
     }

   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   //--- Configure CTrade
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   //--- Initialize day
   datetime now = CurrentServerTime();

   if(now > 0)
      g_day_key = GetDayKey(now);

   //--- Recover existing state
   RecoverState();

   Print("==================================================");
   Print("EA11 initialized");
   Print("Symbol: ", _Symbol);
   Print("Magic Number: ", InpMagicNumber);
   Print("Range: ", InpRangeStartTime,
         " -> ",
         InpRangeEndTime);
   Print("Close Time: ", InpCloseTime);
   Print("Risk Mode: ",
         InpRiskMode == RISK_PERCENTAGE ?
         "Percentage" :
         "Fixed Money");
   Print("TP Multiplier: ",
         DoubleToString(InpTPMultiplier, 2));
   Print("==================================================");

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Do NOT close trades here.
   // The EA must not interfere with positions when removed/reloaded.
   Print("EA11 deinitialized. Reason=", reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   CheckNewDay();

   ProcessStrategy();
  }

//+------------------------------------------------------------------+
//| Trade transaction handler                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   // We only react to transactions involving our symbol/magic.
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD &&
      trans.type != TRADE_TRANSACTION_ORDER_ADD &&
      trans.type != TRADE_TRANSACTION_ORDER_DELETE)
      return;

   // If a position has just been opened from one of our
   // pending orders, remove the opposite pending order.
   if(HasOurPosition())
      DeleteOurPendingOrders();
  }

//+------------------------------------------------------------------+