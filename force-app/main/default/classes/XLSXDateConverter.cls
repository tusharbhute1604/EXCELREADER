public class XLSXDateConverter {
    // Excel's 1900 date system epoch. 
    // Note: Excel considers 1900 a leap year (a legacy Lotus 1-2-3 bug).
    // Serial 1 = Jan 1, 1900. Serial 60 = Feb 29, 1900.
    // For serials > 60, the epoch effectively becomes Dec 30, 1899.
    private static final Date EXCEL_EPOCH = Date.newInstance(1899, 12, 30);
    private static final Date EXCEL_EPOCH_PRE_MARCH_1900 = Date.newInstance(1899, 12, 31);
    
    /**
     * Converts an Excel serial number into a Salesforce Datetime.
     * Excel serials are days since Jan 1, 1900 (with the 1900 leap year bug).
     * The fractional part represents the time of day.
     * Default output is anchored to GMT.
     * 
     * @param serial The Excel serial number (e.g. 44197.5)
     * @return The Salesforce Datetime in GMT
     */
    public static Datetime convertToDatetime(Decimal serial) {
        if (serial == null || serial <= 0) {
            return null; // Invalid or negative serials are not supported
        }

        // Separate the whole days and fractional time
        Integer wholeDays = Integer.valueOf(Math.floor(serial));
        Decimal fractionalDay = serial - wholeDays;

        Date resultDate;
        // Handle the 1900 leap year bug
        if (wholeDays == 60) {
            // Feb 29, 1900 doesn't exist in Salesforce. Map to Feb 28.
            resultDate = Date.newInstance(1900, 2, 28);
        } else if (wholeDays < 60) {
            resultDate = EXCEL_EPOCH_PRE_MARCH_1900.addDays(wholeDays);
        } else {
            resultDate = EXCEL_EPOCH.addDays(wholeDays);
        }

        // Calculate time from fractional part
        Integer totalSecondsInDay = 24 * 60 * 60; // 86400
        Integer secondsSinceMidnight = Integer.valueOf(Math.round(fractionalDay * totalSecondsInDay));

        Integer hours = secondsSinceMidnight / 3600;
        Integer minutes = Math.mod((secondsSinceMidnight / 60), 60);
        Integer seconds = Math.mod(secondsSinceMidnight, 60);

        Time resultTime = Time.newInstance(hours, minutes, seconds, 0);

        // Combine into Datetime in GMT
        return Datetime.newInstanceGmt(resultDate, resultTime);
    }

    /**
     * Converts an Excel serial number directly to a Salesforce Date.
     * 
     * @param serial The Excel serial number
     * @return The Salesforce Date
     */
    public static Date convertToDate(Decimal serial) {
        Datetime dt = convertToDatetime(serial);
        return dt != null ? dt.dateGmt() : null;
    }
}
