@isTest
private class XLSXDateConverterTest {

    @isTest
    static void testPost1900LeapYear() {
        // Excel serial 44197.5 = Jan 1, 2021 12:00:00 PM
        Decimal serial = 44197.5;
        Datetime expected = Datetime.newInstanceGmt(2021, 1, 1, 12, 0, 0);
        
        System.assertEquals(expected, XLSXDateConverter.convertToDatetime(serial), 'Post 1900 date should calculate correctly.');
        System.assertEquals(expected.dateGmt(), XLSXDateConverter.convertToDate(serial), 'Date only extraction should be correct.');
    }
    
    @isTest
    static void testThe1900LeapYearBug() {
        // Excel serial 60 = Feb 29, 1900.
        // Salesforce will map this to Feb 28, 1900.
        Decimal serial = 60.0;
        Datetime expected = Datetime.newInstanceGmt(1900, 2, 28, 0, 0, 0);
        
        System.assertEquals(expected, XLSXDateConverter.convertToDatetime(serial), 'Leap year bug day (Serial 60) should map to Feb 28, 1900.');
    }
    
    @isTest
    static void testPreMarch1900() {
        // Excel serial 59 = Feb 28, 1900.
        Decimal serial = 59.0;
        Datetime expected = Datetime.newInstanceGmt(1900, 2, 28, 0, 0, 0);
        
        System.assertEquals(expected, XLSXDateConverter.convertToDatetime(serial), 'Pre-march 1900 should calculate correctly.');
    }
    
    @isTest
    static void testEpochDay() {
        // Excel serial 1 = Jan 1, 1900.
        Decimal serial = 1.0;
        Datetime expected = Datetime.newInstanceGmt(1900, 1, 1, 0, 0, 0);
        
        System.assertEquals(expected, XLSXDateConverter.convertToDatetime(serial), 'Epoch day (Serial 1) should map to Jan 1, 1900.');
    }
    
    @isTest
    static void testTimeFractions() {
        // 0.25 = 6:00 AM
        // 0.5 = 12:00 PM
        // 0.75 = 6:00 PM
        System.assertEquals(Time.newInstance(6, 0, 0, 0), XLSXDateConverter.convertToDatetime(44197.25).timeGmt(), '0.25 should be 6:00 AM');
        System.assertEquals(Time.newInstance(12, 0, 0, 0), XLSXDateConverter.convertToDatetime(44197.5).timeGmt(), '0.5 should be 12:00 PM');
        System.assertEquals(Time.newInstance(18, 0, 0, 0), XLSXDateConverter.convertToDatetime(44197.75).timeGmt(), '0.75 should be 6:00 PM');
    }
    
    @isTest
    static void testInvalidInputs() {
        System.assertEquals(null, XLSXDateConverter.convertToDatetime(null), 'Null serial should return null.');
        System.assertEquals(null, XLSXDateConverter.convertToDatetime(0), 'Zero serial should return null.');
        System.assertEquals(null, XLSXDateConverter.convertToDatetime(-1), 'Negative serial should return null.');
    }
}
