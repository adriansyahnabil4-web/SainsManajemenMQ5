//+------------------------------------------------------------------+
//|                                                         EA02.mq5 |
//|                                  Copyright 2026, Algorithmic Trader |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.01"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\PositionInfo.mqh>

//--- Enums
enum ENUM_RISK_MODE
{
   RISK_MONETARY, // Fixed Monetary Amount ($)
   RISK_PERCENT   // Percentage of Account Balance (%)
};

//--- Input Parameters
input group "=== 1. Magic & Identification ==="
input ulong    InpMagicNumber          = 888123;      // Magic Number

input group "=== 2. Time Window Settings ==="
input string   InpRangeStartTime       = "03:00";     // Range Start Time (HH:MM)
input string   InpRangeEndTime         = "06:00";     // Range End Time (HH:MM)
input string   InpSessionEndTime       = "18:00";     // Close Orders/Positions Time (HH:MM)

input group "=== 3. Risk & Position Sizing ==="
input ENUM_RISK_MODE InpRiskMode       = RISK_PERCENT;// Risk Mode
input double   InpRiskValue            = 1.0;         // Risk Value ($ or %)

input group "=== 4. Smart Take-Profit Algorithm ==="
input int      InpTPHistoryDepth       = 10;          // X Last Trades for Dynamic TP Average
input double   InpDefaultTPRatio       = 1.5;         // Default TP (Multiplier of Range Height if trades < X)

input group "=== 5. Session Management ==="
input bool     InpClosePositionsAtEnd  = true;        // Close open positions at Session End Time?

//--- Global Objects & Variables
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;

datetime       g_last_range_date       = 0;
datetime       g_last_cleanup_date     = 0;

//+------------------------------------------------------------------+
//| Helper: Format date string YYYY.MM.DD                            |
//+------------------------------------------------------------------+
string GetDateString(datetime time)
{
   return TimeToString(time, TIME_DATE);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetMarginMode();
   trade.SetDeviationInPoints(10);
   
   Print("Time Range Breakout EA Initialized. Magic Number: ", InpMagicNumber);
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
   datetime now = TimeCurrent();
   string currentDateStr = GetDateString(now);

   // Construct today's datetime bounds based on inputs
   datetime rangeStart   = StringToTime(currentDateStr + " " + InpRangeStartTime);
   datetime rangeEnd     = StringToTime(currentDateStr + " " + InpRangeEndTime);
   datetime sessionEnd   = StringToTime(currentDateStr + " " + InpSessionEndTime);

   datetime todayDateOnly = StringToTime(currentDateStr);

   // 1. Process Session End Time Cleanup (Runs once when time crosses sessionEnd)
   if(now >= sessionEnd && g_last_cleanup_date != todayDateOnly)
   {
      CancelPendingOrders();
      if(InpClosePositionsAtEnd)
      {
         CloseAllPositions();
      }
      g_last_cleanup_date = todayDateOnly;
   }

   // 2. Process Range Breakout Setup (Runs once after rangeEnd is passed)
   if(now >= rangeEnd && now < sessionEnd && g_last_range_date != todayDateOnly)
   {
      ExecuteRangeBreakout(rangeStart, rangeEnd, sessionEnd);
      g_last_range_date = todayDateOnly;
   }
}

//+------------------------------------------------------------------+
//| Core Logic: Calculate Range & Place Orders                       |
//+------------------------------------------------------------------+
void ExecuteRangeBreakout(datetime start, datetime end, datetime expiration)
{
   // Check if we already have orders or positions for this Magic Number
   if(HasOpenOrdersOrPositions())
      return;

   int startBar = iBarShift(_Symbol, PERIOD_CURRENT, start, false);
   int endBar   = iBarShift(_Symbol, PERIOD_CURRENT, end, false);

   if(startBar < 0 || endBar < 0 || endBar >= startBar)
   {
      Print("Error: Invalid bar range calculation.");
      return;
   }

   double highestPrice = -1.0;
   double lowestPrice  = 999999.0;

   // Calculate Highest High and Lowest Low within the specified time window
   for(int i = endBar; i <= startBar; i++)
   {
      double high = iHigh(_Symbol, PERIOD_CURRENT, i);
      double low  = iLow(_Symbol, PERIOD_CURRENT, i);
      
      if(high > highestPrice) highestPrice = high;
      if(low < lowestPrice)   lowestPrice  = low;
   }

   if(highestPrice <= 0 || lowestPrice >= 999999.0)
      return;

   double rangePoints = (highestPrice - lowestPrice) / _Point;
   if(rangePoints <= 0) return;

   // Dynamic Take Profit calculation from trading history
   double calculatedTPPoints = CalculateSmartTakeProfit(InpTPHistoryDepth, rangePoints);

   // Calculate Entry, SL, and TP levels
   double buyStopPrice  = NormalizeDouble(highestPrice, _Digits);
   double buySL         = NormalizeDouble(lowestPrice, _Digits);
   double buyTP         = NormalizeDouble(buyStopPrice + (calculatedTPPoints * _Point), _Digits);

   double sellStopPrice = NormalizeDouble(lowestPrice, _Digits);
   double sellSL        = NormalizeDouble(highestPrice, _Digits);
   double sellTP        = NormalizeDouble(sellStopPrice - (calculatedTPPoints * _Point), _Digits);

   // Calculate Risk-Based Lot Size
   double buyRiskDist   = buyStopPrice - buySL;
   double sellRiskDist  = sellSL - sellStopPrice;

   double buyLot        = CalculateLotSize(buyRiskDist);
   double sellLot       = CalculateLotSize(sellRiskDist);

   // Place Buy Stop Order
   if(buyLot > 0)
   {
      trade.BuyStop(buyLot, buyStopPrice, _Symbol, buySL, buyTP, ORDER_TIME_SPECIFIED, expiration);
   }

   // Place Sell Stop Order
   if(sellLot > 0)
   {
      trade.SellStop(sellLot, sellStopPrice, _Symbol, sellSL, sellTP, ORDER_TIME_SPECIFIED, expiration);
   }
}

//+------------------------------------------------------------------+
//| Smart Dynamic Take-Profit Calculation Engine                     |
//+------------------------------------------------------------------+
double CalculateSmartTakeProfit(int depth, double currentRangePoints)
{
   double totalProfitPoints = 0.0;
   int recordedTrades = 0;

   // 1. Check active/open trades managed by this EA
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() == InpMagicNumber && posInfo.Symbol() == _Symbol)
         {
            datetime openTime = (datetime)posInfo.Time();
            double openPrice  = posInfo.PriceOpen();
            ENUM_POSITION_TYPE type = posInfo.PositionType();

            int startBar = iBarShift(_Symbol, PERIOD_M1, openTime);
            double maxDist = 0.0;

            for(int b = startBar; b >= 0; b--)
            {
               if(type == POSITION_TYPE_BUY)
               {
                  double diff = iHigh(_Symbol, PERIOD_M1, b) - openPrice;
                  if(diff > maxDist) maxDist = diff;
               }
               else if(type == POSITION_TYPE_SELL)
               {
                  double diff = openPrice - iLow(_Symbol, PERIOD_M1, b);
                  if(diff > maxDist) maxDist = diff;
               }
            }

            totalProfitPoints += (maxDist / _Point);
            recordedTrades++;

            if(recordedTrades >= depth) break;
         }
      }
   }

   // 2. Scan historical closed deals if active trades < depth
   if(recordedTrades < depth)
   {
      HistorySelect(0, TimeCurrent());
      int totalDeals = HistoryDealsTotal();

      for(int i = totalDeals - 1; i >= 0; i--)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket > 0)
         {
            long dealMagic   = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
            string dealSymbol= HistoryDealGetString(dealTicket, DEAL_SYMBOL);
            long entryType   = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

            if(dealMagic == InpMagicNumber && dealSymbol == _Symbol && entryType == DEAL_ENTRY_IN)
            {
               datetime openTime  = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
               double openPrice   = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
               long type          = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
               ulong positionId   = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

               // Find corresponding close deal time
               datetime closeTime = TimeCurrent();
               for(int j = i + 1; j < totalDeals; j++)
               {
                  ulong cTicket = HistoryDealGetTicket(j);
                  if(HistoryDealGetInteger(cTicket, DEAL_POSITION_ID) == positionId && 
                     HistoryDealGetInteger(cTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
                  {
                     closeTime = (datetime)HistoryDealGetInteger(cTicket, DEAL_TIME);
                     break;
                  }
               }

               int startBar = iBarShift(_Symbol, PERIOD_M1, openTime);
               int endBar   = iBarShift(_Symbol, PERIOD_M1, closeTime);
               double maxDist = 0.0;

               for(int b = startBar; b >= endBar; b--)
               {
                  if(type == DEAL_TYPE_BUY)
                  {
                     double diff = iHigh(_Symbol, PERIOD_M1, b) - openPrice;
                     if(diff > maxDist) maxDist = diff;
                  }
                  else if(type == DEAL_TYPE_SELL)
                  {
                     double diff = openPrice - iLow(_Symbol, PERIOD_M1, b);
                     if(diff > maxDist) maxDist = diff;
                  }
               }

               totalProfitPoints += (maxDist / _Point);
               recordedTrades++;

               if(recordedTrades >= depth) break;
            }
         }
      }
   }

   // Fallback: If not enough history trades found, return dynamic multiplier of range
   if(recordedTrades == 0)
   {
      return currentRangePoints * InpDefaultTPRatio;
   }

   return (totalProfitPoints / recordedTrades);
}

//+------------------------------------------------------------------+
//| Calculate Lot Size Based on Risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double riskDistancePrice)
{
   if(riskDistancePrice <= 0) return 0.0;

   double accBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = 0.0;

   if(InpRiskMode == RISK_MONETARY)
      riskAmount = InpRiskValue;
   else
      riskAmount = accBalance * (InpRiskValue / 100.0);

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tickSize <= 0 || tickValue <= 0) return minLot;

   double riskInTicks = riskDistancePrice / tickSize;
   double moneyPerLot = riskInTicks * tickValue;

   if(moneyPerLot <= 0) return minLot;

   double calculatedLot = riskAmount / moneyPerLot;

   // Normalize lot size according to broker constraints
   calculatedLot = MathFloor(calculatedLot / lotStep) * lotStep;
   calculatedLot = MathMax(minLot, MathMin(maxLot, calculatedLot));

   return calculatedLot;
}

//+------------------------------------------------------------------+
//| Utility: Check existing orders or positions for Magic Number    |
//+------------------------------------------------------------------+
bool HasOpenOrdersOrPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() == InpMagicNumber && posInfo.Symbol() == _Symbol)
            return true;
      }
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(orderInfo.SelectByIndex(i))
      {
         if(orderInfo.Magic() == InpMagicNumber && orderInfo.Symbol() == _Symbol)
            return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Utility: Cancel Pending Orders                                   |
//+------------------------------------------------------------------+
void CancelPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(orderInfo.SelectByIndex(i))
      {
         if(orderInfo.Magic() == InpMagicNumber && orderInfo.Symbol() == _Symbol)
         {
            trade.OrderDelete(orderInfo.Ticket());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Utility: Close All Active Positions                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() == InpMagicNumber && posInfo.Symbol() == _Symbol)
         {
            trade.PositionClose(posInfo.Ticket());
         }
      }
   }
}