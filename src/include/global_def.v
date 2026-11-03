


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// Parenthesize nested macro expressions. Without these parentheses the refresh
// interval expands left-to-right as 64000000/1000000000/125000000/..., which
// truncates to zero and prevents every periodic SDRAM refresh.
`define	  SDR_CLK_PERIOD				(1000000000 / 125000000)
`define   SELF_REFRESH_INTERVAL			(64000000 / `SDR_CLK_PERIOD / (1 << `ROW_WIDTH))

