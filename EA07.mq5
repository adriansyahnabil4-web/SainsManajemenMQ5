//+------------------------------------------------------------------+
//|                                             DailyTimeTrader.mq5 |
//|                                  Copyright 2026, Expert EA Team |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Enums
enum ENUM_RISK_TYPE
  {
   RISK_MONETARY   = 0, // Monetary Amount (Account Currency)
   RISK_PERCENTAGE = 1  // Percentage of Account Balance
  };

//--- Input Parameters
input group "--- General Settings ---"
input ulong            InpMagicNumber   = 123456;      // Magic Number
input string           InpTradeComment  = "TimeTrader"; // Trade Comment

input group "--- Time Settings (HH:MM) ---"
input string           InpOpenTimeStr   = "01:05";     // Position Open Time (Server Time)
input bool             InpUseCloseTime  = true;        // Use Scheduled Close Time
input string           InpCloseTimeStr  = "22:55";     // Position Close Time (Server Time)

input group "--- Risk & Money Management ---"
input ENUM_RISK_TYPE   InpRiskType      = RISK_PERCENTAGE; // Risk Management Type
input double           InpRiskValue     = 1.0;         // Risk Value ($ or % of Balance)
input double           InpStopLossPct   = 1.0;         // Stop Loss (% of Entry Price, 0 = Disabled)
input double           InpTakeProfitPct = 2.0;         // Take Profit (% of Entry Price, 0 = Disabled)

//--- Global Objects & Variables
CTrade         g_trade;
CPositionInfo  g_position;

int            g_openHour, g_openMin;
int            g_closeHour, g_closeMin;
datetime       g_lastOpenDay = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Set magic number for trade operations
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetMarginMode();

   // Parse time strings
   if(!ParseTimeString(InpOpenTimeStr, g_openHour, g_openMin))
     {
      Print("Error: Invalid Open Time format. Expected HH:MM");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpUseCloseTime && !ParseTimeString(InpCloseTimeStr, g_closeHour, g_closeMin))
     {
      Print("Error: Invalid Close Time format. Expected HH:MM");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // Restore state across restarts: check if a trade was already opened today
   g_lastOpenDay = RestoreLastOpenDay();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);

   // Truncate current time to start of day for daily logic comparisons
   datetime todayStart = StructToTime(dt) - (dt.hour * 3600 + dt.min * 60 + dt.sec);

   bool positionExists = HasOpenPosition();

   // --- 1. CLOSING LOGIC ---
   if(InpUseCloseTime && positionExists)
     {
      int currentMinutesFromStart = dt.hour * 60 + dt.min;
      int closeMinutesFromStart   = g_closeHour * 60 + g_closeMin;

      // Close if current time is at or after scheduled close time
      if(currentMinutesFromStart >= closeMinutesFromStart)
        {
         ClosePositions();
         return;
        }
     }

   // --- 2. OPENING LOGIC ---
   if(!positionExists && g_lastOpenDay < todayStart)
     {
      int currentMinutesFromStart = dt.hour * 60 + dt.min;
      int openMinutesFromStart    = g_openHour * 60 + g_openMin;

      // Check if current server time reached or passed entry target
      if(currentMinutesFromStart >= openMinutesFromStart)
        {
         if(ExecuteBuyOrder())
           {
            g_lastOpenDay = todayStart;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Parses HH:MM formatted string into hours and minutes             |
//+------------------------------------------------------------------+
bool ParseTimeString(const string timeStr, int &hour, int &minute)
  {
   string result[];
   if(StringSplit(timeStr, ':', result) != 2)
      return false;

   hour   = (int)StringToInteger(result[0]);
   minute = (int)StringToInteger(result[1]);

   if(hour < 0 || hour > 23 || minute < 0 || minute > 59)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Checks if EA already has an open position under its Magic Number  |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(g_position.SelectByIndex(i))
        {
         if(g_position.Symbol() == _Symbol && g_position.Magic() == InpMagicNumber)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Restores the last daily trade timestamp upon EA reload/restart   |
//+------------------------------------------------------------------+
datetime RestoreLastOpenDay()
  {
   // Check current active positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(g_position.SelectByIndex(i))
        {
         if(g_position.Symbol() == _Symbol && g_position.Magic() == InpMagicNumber)
           {
            datetime posTime = g_position.Time();
            MqlDateTime dt;
            TimeToStruct(posTime, dt);
            return StructToTime(dt) - (dt.hour * 3600 + dt.min * 60 + dt.sec);
           }
        }
     }

   // Check trade history for today's orders if position was already closed
   if(HistorySelect(iTime(_Symbol, PERIOD_D1, 0), TimeCurrent()))
     {
      int totalDeals = HistoryDealsTotal();
      for(int i = 0; i < totalDeals; i++)
        {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket > 0)
           {
            if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol &&
               HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == InpMagicNumber &&
               HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_IN)
              {
               datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
               MqlDateTime dt;
               TimeToStruct(dealTime, dt);
               return StructToTime(dt) - (dt.hour * 3600 + dt.min * 60 + dt.sec);
              }
           }
        }
     }

   return 0;
  }

//+------------------------------------------------------------------+
//| Calculates trade volume based on risk settings and SL percentage|
//+------------------------------------------------------------------+
double CalculateLotSize(double askPrice, double slPrice)
  {
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Calculate monetary risk amount
   double riskAmount = 0.0;
   if(InpRiskType == RISK_MONETARY)
     {
      riskAmount = InpRiskValue;
     }
   else // RISK_PERCENTAGE
     {
      riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskValue / 100.0);
     }

   if(riskAmount <= 0)
      return minLot;

   double lotSize = minLot;

   // If SL percentage is configured, calculate precise lot size based on point risk
   if(InpStopLossPct > 0.0 && slPrice > 0.0)
     {
      double slPoints = (askPrice - slPrice) / _Point;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(slPoints > 0 && tickValue > 0 && tickSize > 0)
        {
         double pointValue = tickValue * (_Point / tickSize);
         lotSize = riskAmount / (slPoints * pointValue);
        }
     }
   else
     {
      // Fallback lot calculation using margin standard if SL is disabled (0%)
      double marginRequired = 0.0;
      if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, askPrice, marginRequired) && marginRequired > 0)
        {
         lotSize = riskAmount / marginRequired;
        }
     }

   // Round to broker step increment and clamp within limits
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

   return lotSize;
  }

//+------------------------------------------------------------------+
//| Opens Buy position with dynamic SL/TP calculation                |
//+------------------------------------------------------------------+
bool ExecuteBuyOrder()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl = (InpStopLossPct > 0.0)   ? NormalizeDouble(ask * (1.0 - (InpStopLossPct / 100.0)), digits) : 0.0;
   double tp = (InpTakeProfitPct > 0.0) ? NormalizeDouble(ask * (1.0 + (InpTakeProfitPct / 100.0)), digits) : 0.0;

   double lotSize = CalculateLotSize(ask, sl);

   if(g_trade.Buy(lotSize, _Symbol, ask, sl, tp, InpTradeComment))
     {
      PrintFormat("Buy position opened successfully. Volume: %.2f, Price: %.*f, SL: %.*f, TP: %.*f",
                  lotSize, digits, ask, digits, sl, digits, tp);
      return true;
     }
   else
     {
      PrintFormat("Error opening Buy position: %d - %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      return false;
     }
  }

//+------------------------------------------------------------------+
//| Closes all positions assigned to EA Magic Number                 |
//+------------------------------------------------------------------+
void ClosePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(g_position.SelectByIndex(i))
        {
         if(g_position.Symbol() == _Symbol && g_position.Magic() == InpMagicNumber)
           {
            ulong ticket = g_position.Ticket();
            if(g_trade.PositionClose(ticket))
              {
               PrintFormat("Position #%I64u closed at scheduled time.", ticket);
              }
            else
              {
               PrintFormat("Failed to close position #%I64u: %d - %s",
                           ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+